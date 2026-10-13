//
// SPDX-FileCopyrightText: 2026 Paul Pardi
// SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit

/// The colour of the globe drawn on a federated participant's avatar, kept free of UIKit view
/// state so it can be unit-tested directly. Mirrors `AvatarWrapper.vue` in the spreed fork.
///
/// The globe's shape says "federated"; its colour says whether they are around. The colours are
/// the ones `AvatarView.setUserStatus()` already draws a *local* participant's badge with, so a
/// federated "away" is the same yellow as a local one and the only difference between the two is
/// the glyph.
///
/// An unrecognised or absent status is deliberately NOT treated as offline: the remote server may
/// simply not have been able to answer, and "we do not know" must stay distinguishable from "they
/// are not there".
enum FederatedPresenceTint {

    static func color(forStatus status: String?) -> UIColor {
        guard let status else { return .label }

        if status == kUserStatusOnline {
            return .systemGreen
        } else if status == kUserStatusAway {
            return .systemYellow
        } else if status == kUserStatusBusy || status == kUserStatusDND {
            return .systemRed
        } else if status == kUserStatusOffline {
            return .secondaryLabel
        }

        // Includes invisible, which the remote server downgrades to offline before it leaves that
        // server. Giving it a colour of its own here would reinvent the distinction it exists to
        // hide, so it falls through to untinted with everything else unrecognised.
        return .label
    }
}
