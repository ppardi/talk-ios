//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
import UserNotifications
@testable import NextcloudTalk

///
/// A notification center a test can look inside.
///
/// Only the pending side can be populated: `UNNotification`, which models a delivered
/// notification, has no public initializer. The removal code treats the two lists identically —
/// same predicate, same ids — so exercising the pending side pins the behavior under test.
///
private final class FakeUserNotificationCenter: UserNotificationCenterProtocol {

    var delegate: UNUserNotificationCenterDelegate?

    var pending: [UNNotificationRequest] = []
    var removedPendingIdentifiers: [String] = []
    var removedDeliveredIdentifiers: [String] = []
    var badgeCount: Int?

    func requestAuthorization(options: UNAuthorizationOptions, completionHandler: @escaping (Bool, Error?) -> Void) {
        completionHandler(true, nil)
    }

    func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: ((Error?) -> Void)?) {
        pending.append(request)
        completionHandler?(nil)
    }

    func getPendingNotificationRequests(completionHandler: @escaping ([UNNotificationRequest]) -> Void) {
        completionHandler(pending)
    }

    func getDeliveredNotifications(completionHandler: @escaping ([UNNotification]) -> Void) {
        completionHandler([])
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removedPendingIdentifiers.append(contentsOf: identifiers)
        pending.removeAll { identifiers.contains($0.identifier) }
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        removedDeliveredIdentifiers.append(contentsOf: identifiers)
    }

    func setBadgeCount(_ newBadgeCount: Int, withCompletionHandler completionHandler: ((Error?) -> Void)?) {
        badgeCount = newBadgeCount
        completionHandler?(nil)
    }
}

///
/// Showing a notification as a banner while the app is in the foreground used to call
/// `removeAllNotifications(forAccountId:)`, which emptied Notification Center of every notification
/// for that account and reset the account's whole notification tally. One banner for one
/// conversation therefore discarded the user's record of every other unread conversation. These
/// tests pin the replacement: only the notification that was actually shown is cleared.
///
final class UnitPresentedNotificationTest: TestBaseRealm {

    private var controller: NCNotificationController!
    private var center: FakeUserNotificationCenter!

    private var accountId: String {
        NCDatabaseManager.sharedInstance().activeAccount().accountId
    }

    override func setUpWithError() throws {
        try super.setUpWithError()

        controller = NCNotificationController()
        center = FakeUserNotificationCenter()
        controller.notificationCenter = center
    }

    /// Queues a pending notification the way the app's own code does: the account and the server's
    /// notification id both live in `userInfo`, which is what the removal predicate reads.
    private func addPendingNotification(id: Int, accountId: String) {
        let content = UNMutableNotificationContent()
        content.userInfo = ["accountId": accountId, "notificationId": id]

        center.pending.append(UNNotificationRequest(identifier: "n\(id)", content: content, trigger: nil))
    }

    func testPresentingABannerRemovesOnlyThatNotification() throws {
        addPendingNotification(id: 1, accountId: accountId)
        addPendingNotification(id: 2, accountId: accountId)
        addPendingNotification(id: 3, accountId: accountId)

        controller.handlePresentedNotification(withUserInfo: ["accountId": accountId, "notificationId": 2])

        XCTAssertEqual(center.removedPendingIdentifiers, ["n2"],
                       "Only the notification that was shown as a banner may be cleared")
        XCTAssertEqual(center.pending.map(\.identifier), ["n1", "n3"],
                       "The other conversations' notifications must survive")
    }

    func testPresentingABannerDoesNotTouchAnotherAccountsNotifications() throws {
        addPendingNotification(id: 1, accountId: accountId)
        addPendingNotification(id: 2, accountId: "someOtherAccount")

        controller.handlePresentedNotification(withUserInfo: ["accountId": "someOtherAccount", "notificationId": 2])

        XCTAssertTrue(center.removedPendingIdentifiers.isEmpty,
                      "A notification for an account that is not active must be left alone")
        XCTAssertEqual(center.pending.count, 2)
    }

    ///
    /// A missed call is shown locally and carries no server notification id. There is nothing to
    /// target, so nothing may be removed — the old code removed everything in this case.
    ///
    func testPresentingANotificationWithoutAnIdRemovesNothing() throws {
        addPendingNotification(id: 1, accountId: accountId)

        controller.handlePresentedNotification(withUserInfo: ["accountId": accountId])

        XCTAssertTrue(center.removedPendingIdentifiers.isEmpty)
        XCTAssertEqual(center.pending.count, 1)
    }

    ///
    /// The tally is what the app icon badge used to be read from directly. Clearing it on a banner
    /// is how a single foreground notification used to hide every unread conversation at once.
    ///
    func testPresentingABannerDoesNotResetTheAccountsNotificationTally() throws {
        addPendingNotification(id: 1, accountId: accountId)
        addPendingNotification(id: 2, accountId: accountId)

        NCDatabaseManager.sharedInstance().increaseUnreadBadgeNumber(forAccountId: accountId)
        NCDatabaseManager.sharedInstance().increaseUnreadBadgeNumber(forAccountId: accountId)

        controller.handlePresentedNotification(withUserInfo: ["accountId": accountId, "notificationId": 2])

        XCTAssertEqual(NCDatabaseManager.sharedInstance().activeAccount().unreadBadgeNumber, 1,
                       "Showing one banner decrements the tally by one, it does not clear it")
    }
}
