//
// SPDX-FileCopyrightText: 2026 Paul Pardi
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Federation-aware capability gates, kept free of Realm and networking so they can be
/// unit-tested directly. Mirrors `canUploadFilesInConversation()` in the spreed fork
/// (`src/utils/attachments.ts`).
///
/// Resolution rules, which differ per capability and are the source of the subtlety here:
/// - `attachments.*` are in the server's `LOCAL_CONFIGS`, so they resolve from the **local**
///   server even for a federated conversation.
/// - `federated-attachments-upload` and `federated-read-status` are in `FEATURES` and not
///   `LOCAL_FEATURES`, so the web resolves them as **local AND host**. iOS's
///   `roomHasTalkCapability()` returns the host's value alone for a federated room, so the
///   caller must pass both and this type ANDs them.
enum FederatedCapabilityGate {

    /// Whether files may be uploaded into the conversation from the device: picked, taken
    /// with the camera, or recorded. Not about sharing an existing Nextcloud file.
    static func canUploadFiles(isFederated: Bool,
                               isPublicRoom: Bool,
                               attachmentsAllowed: Bool,
                               conversationSubfoldersEnabled: Bool,
                               uploadFeatureLocal: Bool,
                               uploadFeatureHost: Bool) -> Bool {
        guard attachmentsAllowed else { return false }
        guard isFederated else { return true }

        // A federated upload has to go through the conversation folder; a flat upload would
        // stay unshared in Talk/, so without subfolder support it must not be offered.
        return !isPublicRoom
            && conversationSubfoldersEnabled
            && uploadFeatureLocal
            && uploadFeatureHost
    }

    /// Whether the "read" delivery state may be shown for the viewer's own messages.
    static func shouldShowReadStatus(isFederated: Bool,
                                     localReadStatusPrivacy: Bool,
                                     readFeatureLocal: Bool,
                                     readFeatureHost: Bool) -> Bool {
        // read-privacy is the viewing user's own preference and always resolves locally.
        guard !localReadStatusPrivacy else { return false }
        guard isFederated else { return true }

        return readFeatureLocal && readFeatureHost
    }
}
