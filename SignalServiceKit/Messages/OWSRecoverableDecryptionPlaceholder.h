//
// Copyright 2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

#import <SignalServiceKit/TSErrorMessage.h>

@class AciObjC;

NS_ASSUME_NONNULL_BEGIN

@interface OWSRecoverableDecryptionPlaceholder : TSErrorMessage <OWSReadTracking>

- (instancetype)initWithGrdbId:(int64_t)grdbId
                        uniqueId:(NSString *)uniqueId
             receivedAtTimestamp:(uint64_t)receivedAtTimestamp
                          sortId:(uint64_t)sortId
                       timestamp:(uint64_t)timestamp
                  uniqueThreadId:(NSString *)uniqueThreadId
                   attachmentIds:(NSArray<NSString *> *)attachmentIds
                            body:(nullable NSString *)body
                      bodyRanges:(nullable MessageBodyRanges *)bodyRanges
                    contactShare:(nullable OWSContact *)contactShare
                       editState:(TSEditState)editState
                 expireStartedAt:(uint64_t)expireStartedAt
                       expiresAt:(uint64_t)expiresAt
                expiresInSeconds:(unsigned int)expiresInSeconds
                       giftBadge:(nullable OWSGiftBadge *)giftBadge
               isGroupStoryReply:(BOOL)isGroupStoryReply
              isViewOnceComplete:(BOOL)isViewOnceComplete
               isViewOnceMessage:(BOOL)isViewOnceMessage
                     linkPreview:(nullable OWSLinkPreview *)linkPreview
                  messageSticker:(nullable MessageSticker *)messageSticker
                   quotedMessage:(nullable TSQuotedMessage *)quotedMessage
    storedShouldStartExpireTimer:(BOOL)storedShouldStartExpireTimer
           storyAuthorUuidString:(nullable NSString *)storyAuthorUuidString
              storyReactionEmoji:(nullable NSString *)storyReactionEmoji
                  storyTimestamp:(nullable NSNumber *)storyTimestamp
              wasRemotelyDeleted:(BOOL)wasRemotelyDeleted
                       errorType:(TSErrorMessageType)errorType
                            read:(BOOL)read
                recipientAddress:(nullable SignalServiceAddress *)recipientAddress
                          sender:(nullable SignalServiceAddress *)sender
             wasIdentityVerified:(BOOL)wasIdentityVerified NS_DESIGNATED_INITIALIZER;

- (instancetype)initErrorMessageWithBuilder:(TSErrorMessageBuilder *)errorMessageBuilder NS_DESIGNATED_INITIALIZER;
- (nullable instancetype)initWithFailedEnvelopeTimestamp:(uint64_t)timestamp
                                               sourceAci:(AciObjC *)sourceAci
                                        untrustedGroupId:(nullable NSData *)untrustedGroupId
                                             transaction:(SDSAnyWriteTransaction *)writeTx NS_DESIGNATED_INITIALIZER;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_DESIGNATED_INITIALIZER;

@property (assign, nonatomic, readonly) BOOL supportsReplacement;

/// After this date, the placeholder is no longer eligible for replacement with the original content.
@property (strong, nonatomic, readonly) NSDate *expirationDate;

// --- CODE GENERATION MARKER

// This snippet is generated by /Scripts/sds_codegen/sds_generate.py. Do not manually edit it, instead run
// `sds_codegen.sh`.

// clang-format off
// clang-format on

// --- CODE GENERATION MARKER

#if TESTABLE_BUILD
- (instancetype)initFakePlaceholderWithTimestamp:(uint64_t)timestamp
                                          thread:(TSThread *)thread
                                          sender:(SignalServiceAddress *)sender;
#endif

@end

NS_ASSUME_NONNULL_END