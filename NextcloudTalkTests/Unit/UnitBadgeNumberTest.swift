//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
@testable import NextcloudTalk

///
/// The app icon badge used to be driven solely by `TalkAccount.unreadBadgeNumber`, a device-local
/// tally that the notification extension increments and that every app activation, every
/// foreground banner and every notification withdrawal decrements or resets wholesale. Nothing
/// ever put a lost count back, so reading one conversation silently dropped the badge for every
/// other one. These tests pin the replacement: a badge derived from the synced room state, which
/// is recomputed from scratch and therefore self-heals.
///
final class UnitBadgeNumberTest: TestBaseRealm {

    private var accountId: String {
        NCDatabaseManager.sharedInstance().activeAccount().accountId
    }

    func testAlwaysNotifyingRoomContributesItsUnreadMessages() throws {
        addRoom(withToken: "always") { room in
            room.unreadMessages = 3
            room.notificationLevel = .always
        }

        XCTAssertEqual(NCDatabaseManager.sharedInstance().numberOfUnreadMessages(forAccountId: accountId), 3)
    }

    func testUnreadMessagesAreSummedAcrossRooms() throws {
        addRoom(withToken: "first") { room in
            room.unreadMessages = 2
            room.notificationLevel = .always
        }

        addRoom(withToken: "second") { room in
            room.unreadMessages = 5
            room.notificationLevel = .always
        }

        XCTAssertEqual(NCDatabaseManager.sharedInstance().numberOfUnreadMessages(forAccountId: accountId), 7)
    }

    func testMutedRoomIsNotCounted() throws {
        addRoom(withToken: "muted") { room in
            room.unreadMessages = 9
            room.notificationLevel = .never
        }

        XCTAssertEqual(NCDatabaseManager.sharedInstance().numberOfUnreadMessages(forAccountId: accountId), 0)
    }

    func testArchivedRoomIsNotCounted() throws {
        addRoom(withToken: "archived") { room in
            room.unreadMessages = 4
            room.notificationLevel = .always
            room.isArchived = true
        }

        XCTAssertEqual(NCDatabaseManager.sharedInstance().numberOfUnreadMessages(forAccountId: accountId), 0)
    }

    func testMentionOnlyGroupRoomIsCountedOnlyWhenMentioned() throws {
        let room = addRoom(withToken: "group") { room in
            room.type = .group
            room.unreadMessages = 6
            room.notificationLevel = .mention
        }

        XCTAssertEqual(NCDatabaseManager.sharedInstance().numberOfUnreadMessages(forAccountId: accountId), 0,
                       "A mentions-only group conversation must not badge for ordinary messages")

        try realm.transaction {
            room.unreadMention = true
        }

        XCTAssertEqual(NCDatabaseManager.sharedInstance().numberOfUnreadMessages(forAccountId: accountId), 6,
                       "Once mentioned, the conversation's unread messages count towards the badge")
    }

    func testDefaultLevelOneToOneRoomIsAlwaysCounted() throws {
        addRoom(withToken: "oneToOne") { room in
            room.type = .oneToOne
            room.unreadMessages = 2
            room.notificationLevel = .default
        }

        XCTAssertEqual(NCDatabaseManager.sharedInstance().numberOfUnreadMessages(forAccountId: accountId), 2)
    }

    ///
    /// `RoomFormatter` resolves `NOTIFY_DEFAULT` into always, mention or never before the
    /// conversation ever reaches the client, so a level still reported as default means the server
    /// did not tell us. The server's own fallback in that branch is always, and a badge too many
    /// costs less than a message missed, so an unresolved level must still badge.
    ///
    func testDefaultLevelGroupRoomIsCountedWithoutAMention() throws {
        addRoom(withToken: "defaultGroup") { room in
            room.type = .group
            room.unreadMessages = 8
            room.notificationLevel = .default
        }

        XCTAssertEqual(NCDatabaseManager.sharedInstance().numberOfUnreadMessages(forAccountId: accountId), 8)
    }

    func testRoomsOfOtherAccountsAreNotCounted() throws {
        addRoom(withToken: "mine") { room in
            room.unreadMessages = 1
            room.notificationLevel = .always
        }

        addRoom(withToken: "theirs", withAccountId: "someOtherAccount") { room in
            room.unreadMessages = 50
            room.notificationLevel = .always
        }

        XCTAssertEqual(NCDatabaseManager.sharedInstance().numberOfUnreadMessages(forAccountId: accountId), 1)
    }

    ///
    /// The defect this whole change exists for: clearing the notification tally — which the app does
    /// on every activation and on every foreground banner — must not be able to hide a conversation
    /// that still has unread messages.
    ///
    func testDerivedBadgeSurvivesResettingTheNotificationTally() throws {
        addRoom(withToken: "unread") { room in
            room.unreadMessages = 4
            room.notificationLevel = .always
        }

        NCDatabaseManager.sharedInstance().increaseUnreadBadgeNumber(forAccountId: accountId)
        NCDatabaseManager.sharedInstance().resetUnreadBadgeNumber(forAccountId: accountId)

        XCTAssertEqual(NCDatabaseManager.sharedInstance().activeAccount().unreadBadgeNumber, 0,
                       "Precondition: the local tally really was cleared")
        XCTAssertEqual(NCDatabaseManager.sharedInstance().numberOfUnreadMessages(forAccountId: accountId), 4,
                       "The badge must still reflect the conversation that has not been read")
    }

    // MARK: - The number actually shown on the app icon

    func testBadgeFallsBackToTheNotificationTallyForMessagesNotYetSynced() throws {
        // A push arrived while the app was in the background, so the extension counted it but the
        // conversation list has not been fetched yet and still shows nothing unread.
        NCDatabaseManager.sharedInstance().increaseUnreadBadgeNumber(forAccountId: accountId)
        NCDatabaseManager.sharedInstance().increaseUnreadBadgeNumber(forAccountId: accountId)

        XCTAssertEqual(NCDatabaseManager.sharedInstance().appIconBadgeNumber(), 2)
    }

    func testBadgeUsesTheConversationsWhenTheyKnowAboutMoreThanTheTally() throws {
        addRoom(withToken: "unread") { room in
            room.unreadMessages = 7
            room.notificationLevel = .always
        }

        NCDatabaseManager.sharedInstance().increaseUnreadBadgeNumber(forAccountId: accountId)

        XCTAssertEqual(NCDatabaseManager.sharedInstance().appIconBadgeNumber(), 7,
                       "The two sources must not be added together — that would count the same message twice")
    }

    func testBadgeIsZeroWhenNothingIsUnread() throws {
        addRoom(withToken: "read") { room in
            room.unreadMessages = 0
            room.notificationLevel = .always
        }

        XCTAssertEqual(NCDatabaseManager.sharedInstance().appIconBadgeNumber(), 0)
    }

    func testBadgeRecoversAfterTheTallyIsClearedWhileMessagesAreStillUnread() throws {
        addRoom(withToken: "stillUnread") { room in
            room.unreadMessages = 3
            room.notificationLevel = .always
        }

        NCDatabaseManager.sharedInstance().increaseUnreadBadgeNumber(forAccountId: accountId)

        // What happens on every app activation and every foreground banner.
        NCDatabaseManager.sharedInstance().resetUnreadBadgeNumber(forAccountId: accountId)

        XCTAssertEqual(NCDatabaseManager.sharedInstance().appIconBadgeNumber(), 3,
                       "Opening the app must not hide a conversation that is still unread")
    }
}
