//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

public class AttachmentManagerImpl: AttachmentManager {

    private let attachmentDownloadManager: AttachmentDownloadManager
    private let attachmentStore: AttachmentStore
    private let orphanedAttachmentCleaner: OrphanedAttachmentCleaner
    private let orphanedAttachmentStore: OrphanedAttachmentStore
    private let stickerManager: Shims.StickerManager

    public init(
        attachmentDownloadManager: AttachmentDownloadManager,
        attachmentStore: AttachmentStore,
        orphanedAttachmentCleaner: OrphanedAttachmentCleaner,
        orphanedAttachmentStore: OrphanedAttachmentStore,
        stickerManager: Shims.StickerManager
    ) {
        self.attachmentDownloadManager = attachmentDownloadManager
        self.attachmentStore = attachmentStore
        self.orphanedAttachmentCleaner = orphanedAttachmentCleaner
        self.orphanedAttachmentStore = orphanedAttachmentStore
        self.stickerManager = stickerManager
    }

    // MARK: - Public

    // MARK: Creating Attachments from source

    public func createAttachmentPointers(
        from protos: [OwnedAttachmentPointerProto],
        tx: DBWriteTransaction
    ) throws {
        guard protos.count < UInt32.max else {
            throw OWSAssertionError("Input array too large")
        }
        try createAttachments(
            protos,
            mimeType: \.proto.contentType,
            owner: \.owner,
            output: \.proto,
            createFn: self._createAttachmentPointer(from:owner:sourceOrder:tx:),
            tx: tx
        )
    }

    public func createAttachmentPointers(
        from backupProtos: [OwnedAttachmentBackupPointerProto],
        uploadEra: String,
        tx: DBWriteTransaction
    ) -> [OwnedAttachmentBackupPointerProto.CreationError] {
        let results = createAttachments(
            backupProtos,
            mimeType: { $0.proto.contentType },
            owner: \.owner,
            output: { $0 },
            createFn: {
                 return self._createAttachmentPointer(
                    from: $0,
                    owner: $1,
                    sourceOrder: $2,
                    uploadEra: uploadEra,
                    tx: $3
                )
            },
            tx: tx
        )
        return results.compactMap { result in
            switch result {
            case .success:
                return nil
            case .failure(let error):
                return error
            }
        }
    }

    public func createAttachmentStreams(
        consuming dataSources: [OwnedAttachmentDataSource],
        tx: DBWriteTransaction
    ) throws {
        guard dataSources.count < UInt32.max else {
            throw OWSAssertionError("Input array too large")
        }
        try createAttachments(
            dataSources,
            mimeType: { $0.mimeType },
            owner: \.owner,
            output: \.source,
            createFn: self._createAttachmentStream(consuming:owner:sourceOrder:tx:),
            tx: tx
        )
    }

    // MARK: Quoted Replies

    public func quotedReplyAttachmentInfo(
        originalMessage: TSMessage,
        tx: DBReadTransaction
    ) -> QuotedAttachmentInfo? {
        guard let originalMessageRowId = originalMessage.sqliteRowId else {
            owsFailDebug("Cloning attachment for un-inserted message")
            return nil
        }
        return _quotedReplyAttachmentInfo(originalMessageRowId: originalMessageRowId, tx: tx)?.info
    }

    public func createQuotedReplyMessageThumbnail(
        consuming dataSource: OwnedQuotedReplyAttachmentDataSource,
        tx: DBWriteTransaction
    ) throws {
        switch dataSource.source.source {
        case .originalAttachment:
            // If the goal is to capture the original message's attachment,
            // ensure we can actually capture its info.
            if let originalMessageRowId = dataSource.source.originalMessageRowId {
                guard
                    let info = _quotedReplyAttachmentInfo(originalMessageRowId: originalMessageRowId, tx: tx),
                    // Not a stub! Stubs would be .unset
                    info.info.info.attachmentType == .V2
                else {
                    return
                }
            }
        case .pendingAttachment, .pointer:
            break
        }
        try _createQuotedReplyMessageThumbnail(
            dataSource: dataSource,
            tx: tx
        )
    }

    // MARK: Removing Attachments

    public func removeAttachment(
        _ attachment: Attachment,
        from owner: AttachmentReference.OwnerId,
        tx: DBWriteTransaction
    ) throws {
        try attachmentStore.removeOwner(
            owner,
            for: attachment.id,
            tx: tx
        )
    }

    public func removeAllAttachments(
        from owners: [AttachmentReference.OwnerId],
        tx: DBWriteTransaction
    ) throws {
        try attachmentStore.fetchReferences(owners: owners, tx: tx)
            .forEach { reference in
                try attachmentStore.removeOwner(
                    reference.owner.id,
                    for: reference.attachmentRowId,
                    tx: tx
                )
            }
    }

    // MARK: - Helpers

    private typealias OwnerId = AttachmentReference.OwnerId
    private typealias OwnerBuilder = AttachmentReference.OwnerBuilder

    // MARK: Creating Attachments from source

    @discardableResult
    private func createAttachments<Input, Output, Result>(
        _ inputArray: [Input],
        mimeType: (Input) -> String?,
        owner: (Input) -> OwnerBuilder,
        output: (Input) -> Output,
        createFn: (Output, OwnerBuilder, UInt32?, DBWriteTransaction) throws -> Result,
        tx: DBWriteTransaction
    ) rethrows -> [Result] {
        var results = [Result]()
        var indexOffset: Int = 0
        for (i, input) in inputArray.enumerated() {
            let sourceOrder: UInt32?
            var ownerForInput = owner(input)
            switch ownerForInput {
            case .messageBodyAttachment(let metadata):
                // Convert text mime type attachments in the first spot to oversize text.
                if mimeType(input) == MimeType.textXSignalPlain.rawValue {
                    ownerForInput = .messageOversizeText(metadata)
                    indexOffset = -1
                    sourceOrder = nil
                } else {
                    sourceOrder = UInt32(i + indexOffset)
                }
            default:
                sourceOrder = nil
                if inputArray.count > 1 {
                    // Only allow multiple attachments in the case of message body attachments.
                    owsFailDebug("Can't have multiple attachments under the same owner reference!")
                }
            }

            let result = try createFn(output(input), ownerForInput, sourceOrder, tx)
            results.append(result)
        }
        return results
    }

    private func _createAttachmentPointer(
        from proto: SSKProtoAttachmentPointer,
        owner: OwnerBuilder,
        // Nil if no order is to be applied.
        sourceOrder: UInt32?,
        tx: DBWriteTransaction
    ) throws {
        let transitTierInfo = try self.transitTierInfo(from: proto)

        let knownIdFromProto: OwnerBuilder.KnownIdInOwner = {
            if
                let uuidData = proto.clientUuid,
                let uuid = UUID(data: uuidData)
            {
                return .known(uuid)
            } else {
                return .knownNil
            }
        }()

        let sourceFilename = proto.fileName
        let mimeType = self.mimeType(
            fromProtoContentType: proto.contentType,
            sourceFilename: sourceFilename
        )

        let attachmentParams = Attachment.ConstructionParams.fromPointer(
            blurHash: proto.blurHash,
            mimeType: mimeType,
            encryptionKey: transitTierInfo.encryptionKey,
            transitTierInfo: transitTierInfo
        )
        let sourceMediaSizePixels: CGSize?
        if
            proto.width > 0,
            let width = CGFloat(exactly: proto.width),
            proto.height > 0,
            let height = CGFloat(exactly: proto.height)
        {
            sourceMediaSizePixels = CGSize(width: width, height: height)
        } else {
            sourceMediaSizePixels = nil
        }

        let referenceParams = AttachmentReference.ConstructionParams(
            owner: try owner.build(
                orderInOwner: sourceOrder,
                knownIdInOwner: knownIdFromProto,
                renderingFlag: .fromProto(proto),
                // Not downloaded so we don't know the content type.
                contentType: nil
            ),
            sourceFilename: sourceFilename,
            sourceUnencryptedByteCount: proto.size,
            sourceMediaSizePixels: sourceMediaSizePixels
        )

        try attachmentStore.insert(
            attachmentParams,
            reference: referenceParams,
            tx: tx
        )

        switch referenceParams.owner {
        case .message(.sticker(let stickerInfo)):
            // Only for stickers, schedule a high priority "download"
            // from the local sticker pack if we have it.
            let installedSticker = self.stickerManager.fetchInstalledSticker(
                packId: stickerInfo.stickerPackId,
                stickerId: stickerInfo.stickerId,
                tx: tx
            )
            if installedSticker != nil {
                guard let newAttachmentReference = attachmentStore.fetchFirstReference(
                    owner: referenceParams.owner.id,
                    tx: tx
                ) else {
                    throw OWSAssertionError("Missing attachment we just created")
                }
                attachmentDownloadManager.enqueueDownloadOfAttachment(
                    id: newAttachmentReference.attachmentRowId,
                    priority: .localClone,
                    source: .transitTier,
                    tx: tx
                )
            }
        default:
            break
        }
    }

    private func transitTierInfo(
        from proto: SSKProtoAttachmentPointer
    ) throws -> Attachment.TransitTierInfo {
        let cdnNumber = proto.cdnNumber
        guard let cdnKey = proto.cdnKey?.nilIfEmpty, cdnNumber > 0 else {
            throw OWSAssertionError("Invalid cdn info")
        }
        guard let encryptionKey = proto.key?.nilIfEmpty else {
            throw OWSAssertionError("Invalid encryption key")
        }
        guard let digestSHA256Ciphertext = proto.digest?.nilIfEmpty else {
            throw OWSAssertionError("Missing digest")
        }

        return .init(
            cdnNumber: cdnNumber,
            cdnKey: cdnKey,
            uploadTimestamp: proto.uploadTimestamp,
            encryptionKey: encryptionKey,
            unencryptedByteCount: proto.size,
            digestSHA256Ciphertext: digestSHA256Ciphertext,
            lastDownloadAttemptTimestamp: nil
        )
    }

    private func _createAttachmentPointer(
        from ownedProto: OwnedAttachmentBackupPointerProto,
        owner: OwnerBuilder,
        // Nil if no order is to be applied.
        sourceOrder: UInt32?,
        uploadEra: String,
        tx: DBWriteTransaction
    ) -> Result<Void, OwnedAttachmentBackupPointerProto.CreationError> {
        let proto = ownedProto.proto

        let knownIdFromProto = ownedProto.clientUUID.map {
            return OwnerBuilder.KnownIdInOwner.known($0)
        } ?? .knownNil

        let sourceFilename = proto.fileName.nilIfEmpty
        let mimeType = self.mimeType(
            fromProtoContentType: proto.contentType,
            sourceFilename: sourceFilename
        )

        let sourceMediaSizePixels: CGSize?
        if
            proto.width > 0,
            let width = CGFloat(exactly: proto.width),
            proto.height > 0,
            let height = CGFloat(exactly: proto.height)
        {
            sourceMediaSizePixels = CGSize(width: width, height: height)
        } else {
            sourceMediaSizePixels = nil
        }

        let attachmentParams: Attachment.ConstructionParams
        let sourceUnencryptedByteCount: UInt32?
        switch proto.locator {
        case .backupLocator(let backupLocator):
            let mediaTierCdnNumber = backupLocator.cdnNumber == 0 ? nil : backupLocator.cdnNumber
            guard let mediaName = backupLocator.mediaName.nilIfEmpty else {
                return .failure(.missingMediaName)
            }
            guard let encryptionKey = backupLocator.key.nilIfEmpty else {
                return .failure(.missingEncryptionKey)
            }
            guard let digestSHA256Ciphertext = backupLocator.digest.nilIfEmpty else {
                return .failure(.missingDigest)
            }
            guard backupLocator.size != 0 else {
                return .failure(.missingSize)
            }

            let transitTierInfo: Attachment.TransitTierInfo?
            switch self.transitTierInfo(from: proto) {
            case .success(let value):
                transitTierInfo = value
            case .failure(let error):
                return .failure(error)
            }

            attachmentParams = .fromBackup(
                blurHash: proto.blurHash.nilIfEmpty,
                mimeType: mimeType,
                encryptionKey: encryptionKey,
                transitTierInfo: transitTierInfo,
                mediaName: mediaName,
                mediaTierInfo: .init(
                    cdnNumber: mediaTierCdnNumber,
                    unencryptedByteCount: backupLocator.size,
                    digestSHA256Ciphertext: digestSHA256Ciphertext,
                    uploadEra: uploadEra,
                    lastDownloadAttemptTimestamp: nil
                ),
                thumbnailMediaTierInfo: .init(
                    // Assume the thumbnail uses the same cdn as fullsize;
                    // this _can_ go wrong if the server changes cdns between
                    // the two uploads but worst case we lose the thumbnail.
                    cdnNumber: mediaTierCdnNumber,
                    uploadEra: uploadEra,
                    lastDownloadAttemptTimestamp: nil
                )
            )
            sourceUnencryptedByteCount = backupLocator.size
        case .attachmentLocator(let attachmentLocator):
            let transitTierInfo: Attachment.TransitTierInfo
            switch self.transitTierInfo(from: proto) {
            case .success(let value):
                guard let value else {
                    return .failure(.missingLocator)
                }
                transitTierInfo = value
            case .failure(let error):
                return .failure(error)
            }
            guard attachmentLocator.size != 0 else {
                return .failure(.missingSize)
            }
            attachmentParams = .fromPointer(
                blurHash: proto.blurHash.nilIfEmpty,
                mimeType: mimeType,
                encryptionKey: transitTierInfo.encryptionKey,
                transitTierInfo: transitTierInfo
            )
            sourceUnencryptedByteCount = attachmentLocator.size
        case .invalidAttachmentLocator, .none:
            attachmentParams = .forInvalidBackupAttachment(
                blurHash: proto.blurHash.nilIfEmpty,
                mimeType: mimeType
            )
            sourceUnencryptedByteCount = nil
        }

        do {
            let referenceParams = AttachmentReference.ConstructionParams(
                owner: try owner.build(
                    orderInOwner: sourceOrder,
                    knownIdInOwner: knownIdFromProto,
                    renderingFlag: ownedProto.renderingFlag,
                    // Not downloaded so we don't know the content type.
                    contentType: nil
                ),
                sourceFilename: sourceFilename,
                sourceUnencryptedByteCount: sourceUnencryptedByteCount,
                sourceMediaSizePixels: sourceMediaSizePixels
            )

            try attachmentStore.insert(
                attachmentParams,
                reference: referenceParams,
                tx: tx
            )

            return .success(())
        } catch {
            return .failure(.dbInsertionError(error))
        }
    }

    private func transitTierInfo(
        from proto: BackupProto_FilePointer
    ) -> Result<Attachment.TransitTierInfo?, OwnedAttachmentBackupPointerProto.CreationError> {
        let cdnNumber: UInt32
        let cdnKey: String
        let encryptionKey: Data
        let unencryptedByteCount: UInt32
        let digest: Data
        let uploadTimestamp: UInt64
        switch proto.locator {
        case .backupLocator(let backupLocator):
            cdnNumber = backupLocator.transitCdnNumber
            cdnKey = backupLocator.transitCdnKey
            encryptionKey = backupLocator.key
            guard backupLocator.size > 0 else {
                return .failure(.missingSize)
            }
            unencryptedByteCount = backupLocator.size
            digest = backupLocator.digest
            // Treat it as uploaded now.
            uploadTimestamp = Date().ows_millisecondsSince1970
        case .attachmentLocator(let attachmentLocator):
            cdnNumber = attachmentLocator.cdnNumber
            cdnKey = attachmentLocator.cdnKey
            encryptionKey = attachmentLocator.key
            unencryptedByteCount = attachmentLocator.size
            digest = attachmentLocator.digest
            uploadTimestamp = attachmentLocator.uploadTimestamp
        case .invalidAttachmentLocator:
            return .success(nil)
        case .none:
            return .failure(.missingLocator)
        }
        guard cdnNumber > 0 else {
            return .failure(.missingTransitCdnNumber)
        }
        guard let cdnKey = cdnKey.nilIfEmpty else {
            return .failure(.missingTransitCdnKey)
        }
        guard let encryptionKey = encryptionKey.nilIfEmpty else {
            return .failure(.missingEncryptionKey)
        }
        guard let digestSHA256Ciphertext = digest.nilIfEmpty else {
            return .failure(.missingDigest)
        }

        return .success(.init(
            cdnNumber: cdnNumber,
            cdnKey: cdnKey,
            uploadTimestamp: uploadTimestamp,
            encryptionKey: encryptionKey,
            unencryptedByteCount: unencryptedByteCount,
            digestSHA256Ciphertext: digestSHA256Ciphertext,
            lastDownloadAttemptTimestamp: nil
        ))
    }

    private func mimeType(
        fromProtoContentType contentType: String?,
        sourceFilename: String?
    ) -> String {
        if let protoMimeType = contentType?.nilIfEmpty {
            return protoMimeType
        } else {
            // Content type might not set if the sending client can't
            // infer a MIME type from the file extension.
            Logger.warn("Invalid attachment content type.")
            if
                let sourceFilename,
                let fileExtension = sourceFilename.fileExtension?.lowercased().nilIfEmpty,
                let inferredMimeType = MimeTypeUtil.mimeTypeForFileExtension(fileExtension)?.nilIfEmpty
            {
                return inferredMimeType
            } else {
                return MimeType.applicationOctetStream.rawValue
            }
        }
    }

    private func _createAttachmentStream(
        consuming dataSource: AttachmentDataSource,
        owner: OwnerBuilder,
        // Nil if no order is to be applied.
        sourceOrder: UInt32?,
        tx: DBWriteTransaction
    ) throws {
        switch dataSource {
        case .existingAttachment(let existingAttachmentMetadata):
            guard let existingAttachment = attachmentStore.fetch(id: existingAttachmentMetadata.id, tx: tx) else {
                throw OWSAssertionError("Missing existing attachment!")
            }

            let owner: AttachmentReference.Owner = try owner.build(
                orderInOwner: sourceOrder,
                knownIdInOwner: .none,
                renderingFlag: existingAttachmentMetadata.renderingFlag,
                contentType: existingAttachment.streamInfo?.contentType.raw
            )
            let referenceParams = AttachmentReference.ConstructionParams(
                owner: owner,
                sourceFilename: existingAttachmentMetadata.sourceFilename,
                sourceUnencryptedByteCount: existingAttachmentMetadata.sourceUnencryptedByteCount,
                sourceMediaSizePixels: existingAttachmentMetadata.sourceMediaSizePixels
            )
            try attachmentStore.addOwner(
                referenceParams,
                for: existingAttachment.id,
                tx: tx
            )
        case .pendingAttachment(let pendingAttachment):
            let owner: AttachmentReference.Owner = try owner.build(
                orderInOwner: sourceOrder,
                knownIdInOwner: .none,
                renderingFlag: pendingAttachment.renderingFlag,
                contentType: pendingAttachment.validatedContentType.raw
            )
            let mediaSizePixels: CGSize?
            switch pendingAttachment.validatedContentType {
            case .invalid, .file, .audio:
                mediaSizePixels = nil
            case .image(let pixelSize), .video(_, let pixelSize, _), .animatedImage(let pixelSize):
                mediaSizePixels = pixelSize
            }
            let referenceParams = AttachmentReference.ConstructionParams(
                owner: owner,
                sourceFilename: pendingAttachment.sourceFilename,
                sourceUnencryptedByteCount: pendingAttachment.unencryptedByteCount,
                sourceMediaSizePixels: mediaSizePixels
            )
            let attachmentParams = Attachment.ConstructionParams.fromStream(
                blurHash: pendingAttachment.blurHash,
                mimeType: pendingAttachment.mimeType,
                encryptionKey: pendingAttachment.encryptionKey,
                streamInfo: .init(
                    sha256ContentHash: pendingAttachment.sha256ContentHash,
                    encryptedByteCount: pendingAttachment.encryptedByteCount,
                    unencryptedByteCount: pendingAttachment.unencryptedByteCount,
                    contentType: pendingAttachment.validatedContentType,
                    digestSHA256Ciphertext: pendingAttachment.digestSHA256Ciphertext,
                    localRelativeFilePath: pendingAttachment.localRelativeFilePath
                ),
                mediaName: Attachment.mediaName(digestSHA256Ciphertext: pendingAttachment.digestSHA256Ciphertext)
            )

            do {
                let hasExistingAttachmentWithSameFile = attachmentStore.fetchAttachment(
                    sha256ContentHash: pendingAttachment.sha256ContentHash,
                    tx: tx
                )?.streamInfo?.localRelativeFilePath == pendingAttachment.localRelativeFilePath
                let hasOrphanRecord = orphanedAttachmentStore.orphanAttachmentExists(
                    with: pendingAttachment.orphanRecordId,
                    tx: tx
                )

                // Typically, we'd expect an orphan record to exist (which ensures that
                // if this creation transaction fails, the file on disk gets cleaned up).
                // However, in AttachmentMultisend we send the same pending attachment file multiple
                // times; the first instance creates an attachment and deletes the orphan record.
                // We can detect this (and know its ok) if the existing attachment uses the same file
                // as our pending attachment; that only happens if it shared the pending attachment.
                guard hasExistingAttachmentWithSameFile || hasOrphanRecord else {
                    throw OWSAssertionError("Attachment file deleted before creation")
                }

                // Try and insert the new attachment.
                try attachmentStore.insert(
                    attachmentParams,
                    reference: referenceParams,
                    tx: tx
                )
                if hasOrphanRecord {
                    // Make sure to clear out the pending attachment from the orphan table so it isn't deleted!
                    try orphanedAttachmentCleaner.releasePendingAttachment(withId: pendingAttachment.orphanRecordId, tx: tx)
                }
            } catch let AttachmentInsertError.duplicatePlaintextHash(existingAttachmentId) {
                // Already have an attachment with the same plaintext hash! Create a new reference to it instead.
                // DO NOT remove the pending attachment's orphan table row, so the pending copy gets cleaned up.
                try attachmentStore.addOwner(
                    referenceParams,
                    for: existingAttachmentId,
                    tx: tx
                )
                return
            } catch let error {
                throw error
            }
        }
    }

    // MARK: Quoted Replies

    private struct WrappedQuotedAttachmentInfo {
        let originalAttachmentReference: AttachmentReference
        let originalAttachment: Attachment
        let info: QuotedAttachmentInfo
    }

    private func _quotedReplyAttachmentInfo(
        originalMessageRowId: Int64,
        tx: DBReadTransaction
    ) -> WrappedQuotedAttachmentInfo? {
        guard
            let originalReference = attachmentStore.attachmentToUseInQuote(
                originalMessageRowId: originalMessageRowId,
                tx: tx
            ),
            let originalAttachment = attachmentStore.fetch(id: originalReference.attachmentRowId, tx: tx)
        else {
            return nil
        }
        return .init(
            originalAttachmentReference: originalReference,
            originalAttachment: originalAttachment,
            info: {
                guard MimeTypeUtil.isSupportedVisualMediaMimeType(originalAttachment.mimeType) else {
                    // Can't make a thumbnail, just return a stub.
                    return .init(
                        info: OWSAttachmentInfo(
                            stubWithMimeType: originalAttachment.mimeType,
                            sourceFilename: originalReference.sourceFilename
                        ),
                        renderingFlag: originalReference.renderingFlag
                    )
                }
                return .init(
                    info: OWSAttachmentInfo(forV2ThumbnailReference: ()),
                    renderingFlag: originalReference.renderingFlag
                )
            }()
        )
    }

    private func _createQuotedReplyMessageThumbnail(
        dataSource: OwnedQuotedReplyAttachmentDataSource,
        tx: DBWriteTransaction
    ) throws {
        let referenceOwner = AttachmentReference.OwnerBuilder.quotedReplyAttachment(dataSource.owner)

        switch dataSource.source.source {
        case .pointer(let proto):
            try self._createAttachmentPointer(
                from: proto,
                owner: referenceOwner,
                sourceOrder: nil,
                tx: tx
            )
        case .pendingAttachment(let pendingAttachment):
            try self._createAttachmentStream(
                consuming: .pendingAttachment(pendingAttachment),
                owner: referenceOwner,
                sourceOrder: nil,
                tx: tx
            )
        case .originalAttachment(let originalAttachmentSource):
            guard let originalAttachment = attachmentStore.fetch(id: originalAttachmentSource.id, tx: tx) else {
                // The original has been deleted.
                throw OWSAssertionError("Original attachment not found")
            }

            let thumbnailMimeType: String
            let thumbnailBlurHash: String?
            let thumbnailTransitTierInfo: Attachment.TransitTierInfo?
            let thumbnailEncryptionKey: Data
            if
                originalAttachment.asStream() == nil,
                let thumbnailProtoFromSender = originalAttachmentSource.thumbnailPointerFromSender,
                let mimeType = thumbnailProtoFromSender.contentType,
                let transitTierInfo = try? self.transitTierInfo(from: thumbnailProtoFromSender)
            {
                // If the original is undownloaded, prefer to use the thumbnail
                // pointer from the sender.
                thumbnailMimeType = mimeType
                thumbnailBlurHash = thumbnailProtoFromSender.blurHash
                thumbnailTransitTierInfo = transitTierInfo
                thumbnailEncryptionKey = transitTierInfo.encryptionKey
            } else {
                // Otherwise fall back to the original's info, leaving transit tier
                // info blank (thumbnail cannot itself be downloaded) in the hopes
                // that we will download the original later and fill the thumbnail in.
                thumbnailMimeType = MimeTypeUtil.thumbnailMimetype(fullsizeMimeType: originalAttachment.mimeType)
                thumbnailBlurHash = originalAttachment.blurHash
                thumbnailTransitTierInfo = nil
                thumbnailEncryptionKey = originalAttachment.encryptionKey
            }

            // Create a new attachment, but add foreign key reference to the original
            // so that when/if we download the original we can update this thumbnail'ed copy.
            let attachmentParams = Attachment.ConstructionParams.forQuotedReplyThumbnailPointer(
                originalAttachment: originalAttachment,
                thumbnailBlurHash: thumbnailBlurHash,
                thumbnailMimeType: thumbnailMimeType,
                thumbnailEncryptionKey: thumbnailEncryptionKey,
                thumbnailTransitTierInfo: thumbnailTransitTierInfo
            )
            let referenceParams = AttachmentReference.ConstructionParams(
                owner: try referenceOwner.build(
                    orderInOwner: nil,
                    knownIdInOwner: .none,
                    renderingFlag: originalAttachmentSource.renderingFlag,
                    contentType: nil
                ),
                sourceFilename: originalAttachmentSource.sourceFilename,
                sourceUnencryptedByteCount: originalAttachmentSource.sourceUnencryptedByteCount,
                sourceMediaSizePixels: originalAttachmentSource.sourceMediaSizePixels
            )

            try attachmentStore.insert(
                attachmentParams,
                reference: referenceParams,
                tx: tx
            )

            // If we know we have a stream, enqueue the download at high priority
            // so that copy happens ASAP.
            if originalAttachment.asStream() != nil {
                guard let newAttachmentReference = attachmentStore.fetchFirstReference(
                    owner: referenceParams.owner.id,
                    tx: tx
                ) else {
                    throw OWSAssertionError("Missing attachment we just created")
                }
                attachmentDownloadManager.enqueueDownloadOfAttachment(
                    id: newAttachmentReference.attachmentRowId,
                    priority: .localClone,
                    source: .transitTier,
                    tx: tx
                )
            }
        }
    }
}

extension AttachmentManagerImpl {
    public enum Shims {
        public typealias StickerManager = _AttachmentManagerImpl_StickerManagerShim
    }

    public enum Wrappers {
        public typealias StickerManager = _AttachmentManagerImpl_StickerManagerWrapper
    }
}

public protocol _AttachmentManagerImpl_StickerManagerShim {
    func fetchInstalledSticker(packId: Data, stickerId: UInt32, tx: DBReadTransaction) -> InstalledSticker?
}

public class _AttachmentManagerImpl_StickerManagerWrapper: _AttachmentManagerImpl_StickerManagerShim {
    public init() {}

    public func fetchInstalledSticker(packId: Data, stickerId: UInt32, tx: DBReadTransaction) -> InstalledSticker? {
        return StickerManager.fetchInstalledSticker(packId: packId, stickerId: stickerId, transaction: SDSDB.shimOnlyBridge(tx))
    }
}
