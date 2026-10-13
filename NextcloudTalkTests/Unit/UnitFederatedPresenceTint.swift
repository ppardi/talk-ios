//
// SPDX-FileCopyrightText: 2026 Paul Pardi
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
import UIKit
@testable import NextcloudTalk

final class UnitFederatedPresenceTint: XCTestCase {

    // MARK: - Known statuses take the colour iOS already uses for a local status

    func testOnlineIsTheSameGreenAsALocalOnlineBadge() {
        XCTAssertEqual(FederatedPresenceTint.color(forStatus: kUserStatusOnline), .systemGreen)
    }

    func testAwayIsTheSameYellowAsALocalAwayBadge() {
        XCTAssertEqual(FederatedPresenceTint.color(forStatus: kUserStatusAway), .systemYellow)
    }

    func testDndIsTheSameRedAsALocalDndBadge() {
        XCTAssertEqual(FederatedPresenceTint.color(forStatus: kUserStatusDND), .systemRed)
    }

    func testBusyIsRedToo() {
        // setUserStatus() draws busy and dnd in the same red; the globe must not disagree.
        XCTAssertEqual(FederatedPresenceTint.color(forStatus: kUserStatusBusy), .systemRed)
    }

    func testOfflineIsGreyAndNotTheUntintedColour() {
        let offline = FederatedPresenceTint.color(forStatus: kUserStatusOffline)
        XCTAssertEqual(offline, .secondaryLabel)
        XCTAssertNotEqual(offline, FederatedPresenceTint.color(forStatus: nil),
                          "offline must stay distinguishable from unknown")
    }

    // MARK: - Unknown stays untinted, which is NOT the same as offline

    func testNoStatusIsUntinted() {
        // A remote server that cannot answer leaves this nil. Claiming "offline" would assert
        // something we do not know.
        XCTAssertEqual(FederatedPresenceTint.color(forStatus: nil), .label)
    }

    func testUnrecognisedTokensAreUntinted() {
        // invisible never arrives -- the server downgrades it to offline before it leaves the
        // remote -- but if it ever did, inventing a colour for it would leak the distinction.
        for token in [kUserStatusInvisible, "garbage", "", "ONLINE", "Away"] {
            XCTAssertEqual(FederatedPresenceTint.color(forStatus: token), .label,
                           "unexpected tint for token '\(token)'")
        }
    }
}
