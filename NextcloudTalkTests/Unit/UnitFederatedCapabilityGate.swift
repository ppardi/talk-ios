//
// SPDX-FileCopyrightText: 2026 Paul Pardi
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
@testable import NextcloudTalk

final class UnitFederatedCapabilityGate: XCTestCase {

    // MARK: - canUploadFiles

    func testLocalRoomOnlyNeedsAttachmentsAllowed() {
        XCTAssertTrue(FederatedCapabilityGate.canUploadFiles(
            isFederated: false, isPublicRoom: false,
            attachmentsAllowed: true, conversationSubfoldersEnabled: false,
            uploadFeatureLocal: false, uploadFeatureHost: false))
    }

    func testAttachmentsDisabledBlocksEverything() {
        XCTAssertFalse(FederatedCapabilityGate.canUploadFiles(
            isFederated: false, isPublicRoom: false,
            attachmentsAllowed: false, conversationSubfoldersEnabled: true,
            uploadFeatureLocal: true, uploadFeatureHost: true))
    }

    func testFederatedRoomNeedsBothServers() {
        XCTAssertTrue(FederatedCapabilityGate.canUploadFiles(
            isFederated: true, isPublicRoom: false,
            attachmentsAllowed: true, conversationSubfoldersEnabled: true,
            uploadFeatureLocal: true, uploadFeatureHost: true))
    }

    // The two negative cases are the whole point of this type: iOS's own
    // roomHasTalkCapability() answers from the HOST alone for a federated room, so a
    // test with the feature enabled on both sides cannot catch a host-only gate.
    func testFederatedRoomRejectedWhenOnlyHostHasFeature() {
        XCTAssertFalse(FederatedCapabilityGate.canUploadFiles(
            isFederated: true, isPublicRoom: false,
            attachmentsAllowed: true, conversationSubfoldersEnabled: true,
            uploadFeatureLocal: false, uploadFeatureHost: true))
    }

    func testFederatedRoomRejectedWhenOnlyLocalHasFeature() {
        XCTAssertFalse(FederatedCapabilityGate.canUploadFiles(
            isFederated: true, isPublicRoom: false,
            attachmentsAllowed: true, conversationSubfoldersEnabled: true,
            uploadFeatureLocal: true, uploadFeatureHost: false))
    }

    // Without conversation subfolders a federated upload would land in Talk/ unshared,
    // so it must not even be offered.
    func testFederatedRoomRequiresConversationSubfolders() {
        XCTAssertFalse(FederatedCapabilityGate.canUploadFiles(
            isFederated: true, isPublicRoom: false,
            attachmentsAllowed: true, conversationSubfoldersEnabled: false,
            uploadFeatureLocal: true, uploadFeatureHost: true))
    }

    func testFederatedPublicRoomIsRejected() {
        XCTAssertFalse(FederatedCapabilityGate.canUploadFiles(
            isFederated: true, isPublicRoom: true,
            attachmentsAllowed: true, conversationSubfoldersEnabled: true,
            uploadFeatureLocal: true, uploadFeatureHost: true))
    }

    func testLocalPublicRoomIsAllowed() {
        XCTAssertTrue(FederatedCapabilityGate.canUploadFiles(
            isFederated: false, isPublicRoom: true,
            attachmentsAllowed: true, conversationSubfoldersEnabled: false,
            uploadFeatureLocal: false, uploadFeatureHost: false))
    }

    // MARK: - shouldShowReadStatus

    func testLocalRoomShowsReadStatusUnlessPrivacyEnabled() {
        XCTAssertTrue(FederatedCapabilityGate.shouldShowReadStatus(
            isFederated: false, localReadStatusPrivacy: false,
            readFeatureLocal: false, readFeatureHost: false))
        XCTAssertFalse(FederatedCapabilityGate.shouldShowReadStatus(
            isFederated: false, localReadStatusPrivacy: true,
            readFeatureLocal: true, readFeatureHost: true))
    }

    func testFederatedReadStatusNeedsBothServers() {
        XCTAssertTrue(FederatedCapabilityGate.shouldShowReadStatus(
            isFederated: true, localReadStatusPrivacy: false,
            readFeatureLocal: true, readFeatureHost: true))
        XCTAssertFalse(FederatedCapabilityGate.shouldShowReadStatus(
            isFederated: true, localReadStatusPrivacy: false,
            readFeatureLocal: false, readFeatureHost: true))
        XCTAssertFalse(FederatedCapabilityGate.shouldShowReadStatus(
            isFederated: true, localReadStatusPrivacy: false,
            readFeatureLocal: true, readFeatureHost: false))
    }

    // Paul's own privacy preference governs, never the host's — read-privacy is in
    // LOCAL_CONFIGS and is populated from getUserReadPrivacy() for the viewing user.
    func testLocalPrivacyWinsOverFederatedCapability() {
        XCTAssertFalse(FederatedCapabilityGate.shouldShowReadStatus(
            isFederated: true, localReadStatusPrivacy: true,
            readFeatureLocal: true, readFeatureHost: true))
    }
}
