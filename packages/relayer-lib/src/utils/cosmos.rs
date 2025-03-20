//! Relayer utilities for `CosmosSDK` chains.

use alloy::{hex, primitives::U256, providers::Provider};
use anyhow::Result;
use ethereum_apis::{beacon_api::client::BeaconApiClient, eth_api::client::EthApiClient};
use ethereum_light_client::membership::evm_ics26_commitment_path;
use ethereum_types::execution::storage_proof::StorageProof;
use futures::future;
use ibc_eureka_solidity_types::ics26::IICS26RouterMsgs::Packet;
use ibc_eureka_utils::rpc::TendermintRpcExt;
use ibc_proto_eureka::{
    ibc::core::{
        channel::v2::{Acknowledgement, MsgAcknowledgement, MsgRecvPacket, MsgTimeout},
        client::v1::Height,
    },
    Protobuf,
};
use tendermint_rpc::HttpClient;

use crate::events::{EurekaEvent, EurekaEventWithHeight};

/// Converts a list of [`EurekaEvent`]s to a list of [`MsgTimeout`]s.
pub fn target_events_to_timeout_msgs(
    target_events: Vec<EurekaEventWithHeight>,
    target_client_id: &str,
    target_height: &Height,
    signer_address: &str,
    now: u64,
) -> Vec<MsgTimeout> {
    target_events
        .into_iter()
        .filter_map(|e| match e.event {
            EurekaEvent::SendPacket(packet) => {
                if now >= packet.timeoutTimestamp && packet.sourceClient == target_client_id {
                    Some(MsgTimeout {
                        packet: Some(packet.into()),
                        proof_height: Some(*target_height),
                        proof_unreceived: vec![],
                        signer: signer_address.to_string(),
                    })
                } else {
                    None
                }
            }
            EurekaEvent::WriteAcknowledgement(..) => None,
        })
        .collect()
}

/// Converts a list of [`EurekaEvent`]s to a list of [`MsgRecvPacket`]s and
/// [`MsgAcknowledgement`]s.
pub fn src_events_to_recv_and_ack_msgs(
    src_events: Vec<EurekaEventWithHeight>,
    target_client_id: &str,
    target_height: &Height,
    signer_address: &str,
    now: u64,
) -> (Vec<MsgRecvPacket>, Vec<MsgAcknowledgement>) {
    let (src_send_events, src_ack_events): (Vec<_>, Vec<_>) = src_events
        .into_iter()
        .filter(|e| match &e.event {
            EurekaEvent::SendPacket(packet) => {
                packet.timeoutTimestamp > now && packet.destClient == target_client_id
            }
            EurekaEvent::WriteAcknowledgement(packet, _) => packet.sourceClient == target_client_id,
        })
        .partition(|e| match e.event {
            EurekaEvent::SendPacket(_) => true,
            EurekaEvent::WriteAcknowledgement(..) => false,
        });

    let recv_msgs = src_send_events
        .into_iter()
        .map(|e| match e.event {
            EurekaEvent::SendPacket(packet) => MsgRecvPacket {
                packet: Some(packet.into()),
                proof_height: Some(*target_height),
                proof_commitment: vec![],
                signer: signer_address.to_string(),
            },
            EurekaEvent::WriteAcknowledgement(..) => unreachable!(),
        })
        .collect::<Vec<MsgRecvPacket>>();

    let ack_msgs = src_ack_events
        .into_iter()
        .map(|e| match e.event {
            EurekaEvent::WriteAcknowledgement(packet, acks) => MsgAcknowledgement {
                packet: Some(packet.into()),
                acknowledgement: Some(Acknowledgement {
                    app_acknowledgements: acks.into_iter().map(Into::into).collect(),
                }),
                proof_height: Some(*target_height),
                proof_acked: vec![],
                signer: signer_address.to_string(),
            },
            EurekaEvent::SendPacket(_) => unreachable!(),
        })
        .collect::<Vec<MsgAcknowledgement>>();

    (recv_msgs, ack_msgs)
}

/// Generates and injects tendermint proofs for rec, ack and timeout messages.
/// # Errors
/// Returns an error a proof cannot be generated for any of the provided messages.
pub async fn inject_tendermint_proofs(
    recv_msgs: &mut [MsgRecvPacket],
    ack_msgs: &mut [MsgAcknowledgement],
    timeout_msgs: &mut [MsgTimeout],
    source_tm_client: &HttpClient,
    target_height: &Height,
) -> Result<()> {
    future::try_join_all(recv_msgs.iter_mut().map(|msg| async {
        let packet: Packet = msg.packet.clone().unwrap().into();
        let commitment_path = packet.commitment_path();
        let (value, proof) = source_tm_client
            .prove_path(
                &[b"ibc".to_vec(), commitment_path],
                target_height.revision_height,
            )
            .await?;
        if value.is_empty() {
            anyhow::bail!("Membership value is empty")
        }

        msg.proof_commitment = proof.encode_vec();
        msg.proof_height = Some(*target_height);
        anyhow::Ok(())
    }))
    .await?;

    future::try_join_all(ack_msgs.iter_mut().map(|msg| async {
        let packet: Packet = msg.packet.clone().unwrap().into();
        let ack_path = packet.ack_commitment_path();
        let (value, proof) = source_tm_client
            .prove_path(&[b"ibc".to_vec(), ack_path], target_height.revision_height)
            .await?;
        if value.is_empty() {
            anyhow::bail!("Membership value is empty")
        }

        msg.proof_acked = proof.encode_vec();
        msg.proof_height = Some(*target_height);
        anyhow::Ok(())
    }))
    .await?;

    future::try_join_all(timeout_msgs.iter_mut().map(|msg| async {
        let packet: Packet = msg.packet.clone().unwrap().into();
        let receipt_path = packet.receipt_commitment_path();
        let (value, proof) = source_tm_client
            .prove_path(
                &[b"ibc".to_vec(), receipt_path],
                target_height.revision_height,
            )
            .await?;

        if !value.is_empty() {
            anyhow::bail!("Non-Membership value is empty")
        }
        msg.proof_unreceived = proof.encode_vec();
        msg.proof_height = Some(*target_height);
        anyhow::Ok(())
    }))
    .await?;

    Ok(())
}

#[allow(clippy::too_many_arguments)]
pub async fn inject_ethereum_proofs<P: Provider + Clone>(
    recv_msgs: &mut [MsgRecvPacket],
    ack_msgs: &mut [MsgAcknowledgement],
    timeout_msgs: &mut [MsgTimeout],
    eth_client: &EthApiClient<P>,
    beacon_api_client: &BeaconApiClient,
    ibc_contrct_address: &str,
    ibc_contract_slot: U256,
    proof_slot: u64,
) -> Result<()> {
    let current_beacon_block = beacon_api_client
        .beacon_block(&format!("{proof_slot:?}"))
        .await?;

    let proof_block_number = current_beacon_block
        .message
        .body
        .execution_payload
        .block_number;

    let proof_slot_height = Height {
        revision_number: 0,
        revision_height: proof_slot,
    };
    // recv messages
    future::try_join_all(recv_msgs.iter_mut().map(|msg| async {
        let packet: Packet = msg.packet.clone().unwrap().into();
        let commitment_path = packet.commitment_path();
        let storage_proof = get_commitment_proof(
            eth_client,
            ibc_contrct_address,
            proof_block_number,
            commitment_path,
            ibc_contract_slot,
        )
        .await?;
        if storage_proof.value.is_zero() {
            anyhow::bail!("Membership value is empty")
        }

        msg.proof_commitment = serde_json::to_vec(&storage_proof)?;
        msg.proof_height = Some(proof_slot_height);
        anyhow::Ok(())
    }))
    .await?;

    // ack messages
    future::try_join_all(ack_msgs.iter_mut().map(|msg| async {
        let packet: Packet = msg.packet.clone().unwrap().into();
        let ack_path = packet.ack_commitment_path();
        let storage_proof = get_commitment_proof(
            eth_client,
            ibc_contrct_address,
            proof_block_number,
            ack_path,
            ibc_contract_slot,
        )
        .await?;
        if storage_proof.value.is_zero() {
            anyhow::bail!("Membership value is empty")
        }

        msg.proof_acked = serde_json::to_vec(&storage_proof)?;
        msg.proof_height = Some(proof_slot_height);
        anyhow::Ok(())
    }))
    .await?;

    // timeout messages
    future::try_join_all(timeout_msgs.iter_mut().map(|msg| async {
        let packet: Packet = msg.packet.clone().unwrap().into();
        let receipt_path = packet.receipt_commitment_path();
        let storage_proof = get_commitment_proof(
            eth_client,
            ibc_contrct_address,
            proof_block_number,
            receipt_path,
            ibc_contract_slot,
        )
        .await?;
        if !storage_proof.value.is_zero() {
            anyhow::bail!("Non-Membership value is empty")
        }
        msg.proof_unreceived = serde_json::to_vec(&storage_proof)?;
        msg.proof_height = Some(proof_slot_height);
        anyhow::Ok(())
    }))
    .await?;

    Ok(())
}

async fn get_commitment_proof<P: Provider + Clone>(
    eth_client: &EthApiClient<P>,
    ibc_contrct_address: &str,
    block_number: u64,
    path: Vec<u8>,
    slot: U256,
) -> Result<StorageProof> {
    let storage_key = evm_ics26_commitment_path(&path, slot);
    let storage_key_be_bytes = storage_key.to_be_bytes_vec();
    let storage_key_hex = hex::encode(storage_key_be_bytes);
    let block_hex = format!("0x{block_number:x}");

    let proof = eth_client
        .get_proof(ibc_contrct_address, vec![storage_key_hex], block_hex)
        .await?;
    let storage_proof = proof.storage_proof.first().unwrap();

    Ok(StorageProof {
        key: storage_proof.key.as_b256(),
        value: storage_proof.value,
        proof: storage_proof.proof.clone(),
    })
}

pub fn inject_mock_proofs(
    recv_msgs: &mut [MsgRecvPacket],
    ack_msgs: &mut [MsgAcknowledgement],
    timeout_msgs: &mut [MsgTimeout],
) {
    for msg in recv_msgs.iter_mut() {
        msg.proof_commitment = b"mock".to_vec();
        msg.proof_height = Some(Height::default());
    }

    for msg in ack_msgs.iter_mut() {
        msg.proof_acked = b"mock".to_vec();
        msg.proof_height = Some(Height::default());
    }

    for msg in timeout_msgs.iter_mut() {
        msg.proof_unreceived = b"mock".to_vec();
        msg.proof_height = Some(Height::default());
    }
}
