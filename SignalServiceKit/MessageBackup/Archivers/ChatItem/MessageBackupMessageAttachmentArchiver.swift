//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import LibSignalClient

internal class MessageBackupMessageAttachmentArchiver: MessageBackupProtoArchiver {
    private typealias ArchiveFrameError = MessageBackup.ArchiveFrameError<MessageBackup.InteractionUniqueId>

    private let attachmentManager: AttachmentManager
    private let attachmentStore: AttachmentStore
    private let backupAttachmentDownloadStore: BackupAttachmentDownloadStore

    init(
        attachmentManager: AttachmentManager,
        attachmentStore: AttachmentStore,
        backupAttachmentDownloadStore: BackupAttachmentDownloadStore
    ) {
        self.attachmentManager = attachmentManager
        self.attachmentStore = attachmentStore
        self.backupAttachmentDownloadStore = backupAttachmentDownloadStore
    }

    // MARK: - Archiving

    func archiveBodyAttachments(
        _ message: TSMessage,
        context: MessageBackup.RecipientArchivingContext,
        tx: DBReadTransaction
    ) -> MessageBackup.ArchiveInteractionResult<[BackupProto_FilePointer]> {
        // TODO: convert message's attachments into proto

        // TODO: enqueue upload of message's attachments to media tier (& thumbnail)

        return .success([])
    }

    // MARK: Restoring

    public func restoreBodyAttachments(
        _ attachments: [BackupProto_MessageAttachment],
        chatItemId: MessageBackup.ChatItemId,
        messageRowId: Int64,
        message: TSMessage,
        thread: MessageBackup.ChatThread,
        context: MessageBackup.RestoringContext
    ) -> MessageBackup.RestoreInteractionResult<Void> {
        var uuidErrors = [MessageBackup.RestoreFrameError<MessageBackup.ChatItemId>.ErrorType.InvalidProtoDataError]()
        let withUnwrappedUUIDs: [(BackupProto_MessageAttachment, UUID?)]
        withUnwrappedUUIDs = attachments.map { attachment in
            if attachment.hasClientUuid {
                guard let uuid = UUID(data: attachment.clientUuid) else {
                    uuidErrors.append(.invalidAttachmentClientUUID)
                    return (attachment, nil)
                }
                return (attachment, uuid)
            } else {
                return (attachment, nil)
            }
        }
        guard uuidErrors.isEmpty else {
            return .messageFailure(uuidErrors.map {
                .restoreFrameError(.invalidProtoData($0), chatItemId)
            })
        }

        let ownedAttachments = withUnwrappedUUIDs.map { attachment, clientUUID in
            return OwnedAttachmentBackupPointerProto(
                proto: attachment.pointer,
                renderingFlag: attachment.flag.asAttachmentFlag,
                clientUUID: clientUUID,
                owner: .messageBodyAttachment(.init(
                    messageRowId: messageRowId,
                    receivedAtTimestamp: message.receivedAtTimestamp,
                    threadRowId: thread.threadRowId
                ))
            )
        }

        return restoreAttachments(
            ownedAttachments,
            chatItemId: chatItemId,
            context: context
        )
    }

    public func restoreOversizeTextAttachment(
        _ attachment: BackupProto_FilePointer,
        chatItemId: MessageBackup.ChatItemId,
        messageRowId: Int64,
        message: TSMessage,
        thread: MessageBackup.ChatThread,
        context: MessageBackup.RestoringContext
    ) -> MessageBackup.RestoreInteractionResult<Void> {
        let ownedAttachment = OwnedAttachmentBackupPointerProto(
            proto: attachment,
            // Oversize text attachments have no flags
            renderingFlag: .default,
            // ClientUUID is only for body and quoted reply attachments.
            clientUUID: nil,
            owner: .messageOversizeText(.init(
                messageRowId: messageRowId,
                receivedAtTimestamp: message.receivedAtTimestamp,
                threadRowId: thread.threadRowId
            ))
        )

        return restoreAttachments(
            [ownedAttachment],
            chatItemId: chatItemId,
            context: context
        )
    }

    public func restoreQuotedReplyThumbnailAttachment(
        _ attachment: BackupProto_MessageAttachment,
        chatItemId: MessageBackup.ChatItemId,
        messageRowId: Int64,
        message: TSMessage,
        thread: MessageBackup.ChatThread,
        context: MessageBackup.RestoringContext
    ) -> MessageBackup.RestoreInteractionResult<Void> {
        let clientUUID: UUID?
        if attachment.hasClientUuid {
            guard let uuid = UUID(data: attachment.clientUuid) else {
                return .messageFailure([.restoreFrameError(
                    .invalidProtoData(.invalidAttachmentClientUUID),
                    chatItemId
                )])
            }
            clientUUID = uuid
        } else {
            clientUUID = nil
        }

        let ownedAttachment = OwnedAttachmentBackupPointerProto(
            proto: attachment.pointer,
            renderingFlag: attachment.flag.asAttachmentFlag,
            clientUUID: clientUUID,
            owner: .quotedReplyAttachment(.init(
                messageRowId: messageRowId,
                receivedAtTimestamp: message.receivedAtTimestamp,
                threadRowId: thread.threadRowId
            ))
        )

        return restoreAttachments(
            [ownedAttachment],
            chatItemId: chatItemId,
            context: context
        )
    }

    public func restoreLinkPreviewAttachment(
        _ attachment: BackupProto_FilePointer,
        chatItemId: MessageBackup.ChatItemId,
        messageRowId: Int64,
        message: TSMessage,
        thread: MessageBackup.ChatThread,
        context: MessageBackup.RestoringContext
    ) -> MessageBackup.RestoreInteractionResult<Void> {
        let ownedAttachment = OwnedAttachmentBackupPointerProto(
            proto: attachment,
            // Link previews have no flags
            renderingFlag: .default,
            // ClientUUID is only for body and quoted reply attachments.
            clientUUID: nil,
            owner: .messageLinkPreview(.init(
                messageRowId: messageRowId,
                receivedAtTimestamp: message.receivedAtTimestamp,
                threadRowId: thread.threadRowId
            ))
        )

        return restoreAttachments(
            [ownedAttachment],
            chatItemId: chatItemId,
            context: context
        )
    }

    public func restoreContactAvatarAttachment(
        _ attachment: BackupProto_FilePointer,
        chatItemId: MessageBackup.ChatItemId,
        messageRowId: Int64,
        message: TSMessage,
        thread: MessageBackup.ChatThread,
        context: MessageBackup.RestoringContext
    ) -> MessageBackup.RestoreInteractionResult<Void> {
        let ownedAttachment = OwnedAttachmentBackupPointerProto(
            proto: attachment,
            // Contact share avatars have no flags
            renderingFlag: .default,
            // ClientUUID is only for body and quoted reply attachments.
            clientUUID: nil,
            owner: .messageContactAvatar(.init(
                messageRowId: messageRowId,
                receivedAtTimestamp: message.receivedAtTimestamp,
                threadRowId: thread.threadRowId
            ))
        )

        return restoreAttachments(
            [ownedAttachment],
            chatItemId: chatItemId,
            context: context
        )
    }

    public func restoreStickerAttachment(
        _ attachment: BackupProto_FilePointer,
        stickerPackId: Data,
        stickerId: UInt32,
        chatItemId: MessageBackup.ChatItemId,
        messageRowId: Int64,
        message: TSMessage,
        thread: MessageBackup.ChatThread,
        context: MessageBackup.RestoringContext
    ) -> MessageBackup.RestoreInteractionResult<Void> {
        let ownedAttachment = OwnedAttachmentBackupPointerProto(
            proto: attachment,
            // Sticker messages have no flags
            renderingFlag: .default,
            // ClientUUID is only for body and quoted reply attachments.
            clientUUID: nil,
            owner: .messageSticker(.init(
                messageRowId: messageRowId,
                receivedAtTimestamp: message.receivedAtTimestamp,
                threadRowId: thread.threadRowId,
                stickerPackId: stickerPackId,
                stickerId: stickerId
            ))
        )

        return restoreAttachments(
            [ownedAttachment],
            chatItemId: chatItemId,
            context: context
        )
    }

    internal static func uploadEra() throws -> String {
        // TODO: [Backups] use actual subscription id. For now use a fixed,
        // arbitrary id, so that it never changes.
        let backupSubscriptionId = Data(repeating: 5, count: 32)
        return try Attachment.uploadEra(backupSubscriptionId: backupSubscriptionId)
    }

    internal static func isFreeTierBackup() -> Bool {
        // TODO: [Backups] need a way to check if we are a free tier user;
        // if so we only use the AttachmentLocator instead of BackupLocator.
        return false
    }

    private func restoreAttachments(
        _ attachments: [OwnedAttachmentBackupPointerProto],
        chatItemId: MessageBackup.ChatItemId,
        context: MessageBackup.RestoringContext
    ) -> MessageBackup.RestoreInteractionResult<Void> {
        let uploadEra: String
        do {
            uploadEra = try Self.uploadEra()
        } catch {
            return .messageFailure([.restoreFrameError(
                .uploadEraDerivationFailed(error),
                chatItemId
            )])
        }

        let errors = attachmentManager.createAttachmentPointers(
            from: attachments,
            uploadEra: uploadEra,
            tx: context.tx
        )

        guard errors.isEmpty else {
            // Treat attachment failures as message failures; a message
            // might have _only_ attachments and without them its invalid.
            return .messageFailure(errors.map {
                return .restoreFrameError(
                    .fromAttachmentCreationError($0),
                    chatItemId
                )
            })
        }

        let results = attachmentStore.fetchReferences(owners: attachments.map(\.owner.id), tx: context.tx)
        if results.isEmpty && !attachments.isEmpty {
            return .messageFailure([.restoreFrameError(
                .failedToCreateAttachment,
                chatItemId
            )])
        }

        do {
            try results.forEach {
                try backupAttachmentDownloadStore.enqueue($0, tx: context.tx)
            }
        } catch {
            return .partialRestore((), [.restoreFrameError(
                .failedToEnqueueAttachmentDownload(error),
                chatItemId
            )])
        }

        return .success(())
    }
}

extension BackupProto_MessageAttachment.Flag {

    fileprivate var asAttachmentFlag: AttachmentReference.RenderingFlag {
        switch self {
        case .none, .UNRECOGNIZED:
            return .default
        case .voiceMessage:
            return .voiceMessage
        case .borderless:
            return .borderless
        case .gif:
            return .shouldLoop
        }
    }
}

extension MessageBackup.RestoreFrameError.ErrorType {

    internal static func fromAttachmentCreationError(
        _ error: OwnedAttachmentBackupPointerProto.CreationError
    ) -> Self {
        switch error {
        case .missingLocator:
            return .invalidProtoData(.filePointerMissingLocator)
        case .missingTransitCdnNumber:
            return .invalidProtoData(.filePointerMissingTransitCdnNumber)
        case .missingTransitCdnKey:
            return .invalidProtoData(.filePointerMissingTransitCdnKey)
        case .missingMediaName:
            return .invalidProtoData(.filePointerMissingMediaName)
        case .missingEncryptionKey:
            return .invalidProtoData(.filePointerMissingEncryptionKey)
        case .missingDigest:
            return .invalidProtoData(.filePointerMissingDigest)
        case .missingSize:
            return .invalidProtoData(.filePointerMissingSize)
        case .dbInsertionError(let error):
            return .databaseInsertionFailed(error)
        }
    }
}

extension ReferencedAttachment {

    internal func asBackupFilePointer(
        isFreeTierBackup: Bool
    ) -> BackupProto_FilePointer {
        var proto = BackupProto_FilePointer()
        proto.contentType = attachment.mimeType
        if let sourceFilename = reference.sourceFilename {
            proto.fileName = sourceFilename
        }
        if let caption = reference.legacyMessageCaption {
            proto.caption = caption
        }
        if let blurHash = attachment.blurHash {
            proto.blurHash = blurHash
        }

        switch attachment.streamInfo?.contentType {
        case
                .animatedImage(let pixelSize),
                .image(let pixelSize),
                .video(_, let pixelSize, _):
            proto.width = UInt32(pixelSize.width)
            proto.height = UInt32(pixelSize.height)
        case .audio, .file, .invalid:
            break
        case nil:
            if let mediaSize = reference.sourceMediaSizePixels {
                proto.width = UInt32(mediaSize.width)
                proto.height = UInt32(mediaSize.height)
            }
        }

        let locator: BackupProto_FilePointer.OneOf_Locator
        if
            // We only create the backup locator for non-free tier backups.
            !isFreeTierBackup,
            let mediaName = attachment.mediaName,
            let mediaTierDigest =
                attachment.mediaTierInfo?.digestSHA256Ciphertext
                ?? attachment.streamInfo?.digestSHA256Ciphertext,
            let mediaTierUnencryptedByteCount =
                attachment.mediaTierInfo?.unencryptedByteCount
                ?? attachment.streamInfo?.unencryptedByteCount
        {
            var backupLocator = BackupProto_FilePointer.BackupLocator()
            backupLocator.mediaName = mediaName
            // Backups use the same encryption key we use locally, always.
            backupLocator.key = attachment.encryptionKey
            backupLocator.digest = mediaTierDigest
            backupLocator.size = mediaTierUnencryptedByteCount

            // We may not have uploaded yet, so we may not know the cdn number.
            // Set it if we have it; its ok if we don't.
            if let cdnNumber = attachment.mediaTierInfo?.cdnNumber {
                backupLocator.cdnNumber = cdnNumber
            }
            if let transitTierInfo = attachment.transitTierInfo {
                backupLocator.transitCdnKey = transitTierInfo.cdnKey
                backupLocator.transitCdnNumber = transitTierInfo.cdnNumber
            }
            locator = .backupLocator(backupLocator)
        } else if
            let transitTierInfo = attachment.transitTierInfo
        {
            var transitTierLocator = BackupProto_FilePointer.AttachmentLocator()
            transitTierLocator.cdnKey = transitTierInfo.cdnKey
            transitTierLocator.cdnNumber = transitTierInfo.cdnNumber
            transitTierLocator.uploadTimestamp = transitTierInfo.uploadTimestamp
            transitTierLocator.key = transitTierInfo.encryptionKey
            transitTierLocator.digest = transitTierInfo.digestSHA256Ciphertext
            if let unencryptedByteCount = transitTierInfo.unencryptedByteCount {
                transitTierLocator.size = unencryptedByteCount
            }
            locator = .attachmentLocator(transitTierLocator)
        } else {
            locator = .invalidAttachmentLocator(BackupProto_FilePointer.InvalidAttachmentLocator())
        }

        proto.locator = locator

        // Notes:
        // * incrementalMac and incrementalMacChunkSize unsupported by iOS
        return proto
    }
}
