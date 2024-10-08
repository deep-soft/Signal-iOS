//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import LibSignalClient

internal class MessageBackupTSOutgoingMessageArchiver: MessageBackupProtoArchiver {
    typealias Details = MessageBackup.InteractionArchiveDetails

    private typealias ArchiveFrameError = MessageBackup.ArchiveFrameError<MessageBackup.InteractionUniqueId>

    private let contentsArchiver: MessageBackupTSMessageContentsArchiver
    private let interactionStore: InteractionStore
    private let sentMessageTranscriptReceiver: SentMessageTranscriptReceiver

    internal init(
        contentsArchiver: MessageBackupTSMessageContentsArchiver,
        interactionStore: InteractionStore,
        sentMessageTranscriptReceiver: SentMessageTranscriptReceiver
    ) {
        self.contentsArchiver = contentsArchiver
        self.interactionStore = interactionStore
        self.sentMessageTranscriptReceiver = sentMessageTranscriptReceiver
    }

    // MARK: - Archiving

    func archiveOutgoingMessage(
        _ message: TSOutgoingMessage,
        thread _: TSThread,
        context: MessageBackup.ChatArchivingContext,
        tx: DBReadTransaction
    ) -> MessageBackup.ArchiveInteractionResult<Details> {
        var partialErrors = [ArchiveFrameError]()

        let wasAnySendSealedSender: Bool
        let directionalDetails: Details.DirectionalDetails
        switch buildOutgoingMessageDetails(
            message,
            recipientContext: context.recipientContext
        ).bubbleUp(Details.self, partialErrors: &partialErrors) {
        case .continue(let details):
            directionalDetails = details.details
            wasAnySendSealedSender = details.wasAnySendSealedSender
        case .bubbleUpError(let errorResult):
            return errorResult
        }

        let contentsResult = contentsArchiver.archiveMessageContents(
            message,
            context: context.recipientContext,
            tx: tx
        )
        let chatItemType: MessageBackup.InteractionArchiveDetails.ChatItemType
        switch contentsResult.bubbleUp(Details.self, partialErrors: &partialErrors) {
        case .continue(let t):
            chatItemType = t
        case .bubbleUpError(let errorResult):
            return errorResult
        }

        let details = Details(
            author: context.recipientContext.localRecipientId,
            directionalDetails: directionalDetails,
            dateCreated: message.timestamp,
            expireStartDate: message.expireStartedAt,
            expiresInMs: UInt64(message.expiresInSeconds) * 1000,
            isSealedSender: wasAnySendSealedSender,
            chatItemType: chatItemType
        )
        if partialErrors.isEmpty {
            return .success(details)
        } else {
            return .partialFailure(details, partialErrors)
        }
    }

    struct OutgoingMessageDetails {
        let details: Details.DirectionalDetails
        let wasAnySendSealedSender: Bool
    }

    private func buildOutgoingMessageDetails(
        _ message: TSOutgoingMessage,
        recipientContext: MessageBackup.RecipientArchivingContext
    ) -> MessageBackup.ArchiveInteractionResult<OutgoingMessageDetails> {
        var perRecipientErrors = [ArchiveFrameError]()

        var wasAnySendSealedSender = false
        var outgoingMessage = BackupProto_ChatItem.OutgoingMessageDetails()

        for (address, sendState) in message.recipientAddressStates ?? [:] {
            guard let recipientAddress = address.asSingleServiceIdBackupAddress()?.asArchivingAddress() else {
                perRecipientErrors.append(.archiveFrameError(
                    .invalidOutgoingMessageRecipient,
                    message.uniqueInteractionId
                ))
                continue
            }
            guard let recipientId = recipientContext[recipientAddress] else {
                perRecipientErrors.append(.archiveFrameError(
                    .referencedRecipientIdMissing(recipientAddress),
                    message.uniqueInteractionId
                ))
                continue
            }
            var isNetworkFailure = false
            var isIdentityKeyMismatchFailure = false
            let protoDeliveryStatus: BackupProto_SendStatus.Status
            let statusTimestamp: UInt64
            switch sendState.state {
            case OWSOutgoingMessageRecipientState.sent:
                if let readTimestamp = sendState.readTimestamp {
                    protoDeliveryStatus = .read
                    statusTimestamp = readTimestamp.uint64Value
                } else if let viewedTimestamp = sendState.viewedTimestamp {
                    protoDeliveryStatus = .viewed
                    statusTimestamp = viewedTimestamp.uint64Value
                } else if let deliveryTimestamp = sendState.deliveryTimestamp {
                    protoDeliveryStatus = .delivered
                    statusTimestamp = deliveryTimestamp.uint64Value
                } else {
                    protoDeliveryStatus = .sent
                    statusTimestamp = message.timestamp
                }
            case OWSOutgoingMessageRecipientState.failed:
                // TODO: [Backups] Identify specific errors (see recipientState.errorCode). For now, call everything network.
                isNetworkFailure = true
                isIdentityKeyMismatchFailure = false
                protoDeliveryStatus = .failed
                statusTimestamp = message.timestamp
            case OWSOutgoingMessageRecipientState.sending, OWSOutgoingMessageRecipientState.pending:
                protoDeliveryStatus = .pending
                statusTimestamp = message.timestamp
            case OWSOutgoingMessageRecipientState.skipped:
                protoDeliveryStatus = .skipped
                statusTimestamp = message.timestamp
            }

            var sendStatus = BackupProto_SendStatus()
            sendStatus.recipientID = recipientId.value
            sendStatus.deliveryStatus = protoDeliveryStatus
            sendStatus.networkFailure = isNetworkFailure
            sendStatus.identityKeyMismatch = isIdentityKeyMismatchFailure
            // TODO: [Backups] Is this check inverted?
            sendStatus.sealedSender = sendState.wasSentByUD.negated
            sendStatus.lastStatusUpdateTimestamp = statusTimestamp

            outgoingMessage.sendStatus.append(sendStatus)

            if sendState.wasSentByUD.negated {
                wasAnySendSealedSender = true
            }
        }

        if perRecipientErrors.isEmpty {
            return .success(OutgoingMessageDetails(
                details: .outgoing(outgoingMessage),
                wasAnySendSealedSender: wasAnySendSealedSender
            ))
        } else {
            return .partialFailure(
                OutgoingMessageDetails(
                    details: .outgoing(outgoingMessage),
                    wasAnySendSealedSender: wasAnySendSealedSender
                ),
                perRecipientErrors
            )
        }
    }

    // MARK: - Restoring

    func restoreChatItem(
        _ chatItem: BackupProto_ChatItem,
        chatThread: MessageBackup.ChatThread,
        context: MessageBackup.ChatRestoringContext,
        tx: DBWriteTransaction
    ) -> MessageBackup.RestoreInteractionResult<Void> {
        let outgoingDetails: BackupProto_ChatItem.OutgoingMessageDetails
        switch chatItem.directionalDetails {
        case .outgoing(let backupProtoChatItemOutgoingMessageDetails):
            outgoingDetails = backupProtoChatItemOutgoingMessageDetails
        case nil, .incoming, .directionless:
            // Should be impossible.
            return .messageFailure([.restoreFrameError(
                .developerError(OWSAssertionError("OutgoingMessageArchiver given non-outgoing message!")),
                chatItem.id
            )])
        }

        guard let chatItemType = chatItem.item else {
            // Unrecognized item type!
            return .messageFailure([.restoreFrameError(.invalidProtoData(.chatItemMissingItem), chatItem.id)])
        }

        var partialErrors = [MessageBackup.RestoreFrameError<MessageBackup.ChatItemId>]()

        let contentsResult = contentsArchiver.restoreContents(
            chatItemType,
            chatItemId: chatItem.id,
            chatThread: chatThread,
            context: context,
            tx: tx
        )

        guard let contents = contentsResult.unwrap(partialErrors: &partialErrors) else {
            return .messageFailure(partialErrors)
        }

        let transcriptResult = RestoredSentMessageTranscript.from(
            chatItem: chatItem,
            contents: contents,
            outgoingDetails: outgoingDetails,
            context: context,
            chatThread: chatThread
        )

        guard let transcript = transcriptResult.unwrap(partialErrors: &partialErrors) else {
            return .messageFailure(partialErrors)
        }

        let messageResult = sentMessageTranscriptReceiver.process(
            transcript,
            localIdentifiers: context.recipientContext.localIdentifiers,
            tx: tx
        )
        let message: TSOutgoingMessage
        switch messageResult {
        case .success(let outgoingMessage):
            guard let outgoingMessage else {
                return .messageFailure(partialErrors)
            }
            message = outgoingMessage
        case .failure(let error):
            partialErrors.append(.restoreFrameError(.databaseInsertionFailed(error), chatItem.id))
            return .messageFailure(partialErrors)
        }

        let downstreamObjectsResult = contentsArchiver.restoreDownstreamObjects(
            message: message,
            thread: chatThread,
            chatItemId: chatItem.id,
            restoredContents: contents,
            context: context,
            tx: tx
        )
        guard downstreamObjectsResult.unwrap(partialErrors: &partialErrors) else {
            return .messageFailure(partialErrors)
        }

        if partialErrors.isEmpty {
            return .success(())
        } else {
            return .partialRestore((), partialErrors)
        }
    }
}
