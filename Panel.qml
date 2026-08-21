import QtQuick
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root

  moduleName: "io.github.gardnmi.omarchy-irc"
  ipcTarget: "io.github.gardnmi.omarchy-irc"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property int barSize: bar ? bar.barSize : Style.bar.sizeHorizontal
  readonly property string helperPath: decodeURIComponent(String(Qt.resolvedUrl("irc_helper.py")))
    .replace(/^file:\/\//, "")
  property string connectionState: "disconnected"
  property string statusMessage: "Choose a guest nickname to join"
  property string nickname: ""
  property int unreadCount: 0
  property bool helperStarted: false
  property bool joined: false
  property int sequence: 0
  property string activeTarget: "#omachee"
  property string selectedUser: ""
  property var users: []
  property var directTargets: []
  property var mutedUsers: ({})
  readonly property var conversationOptions: [{ value: "#omachee", label: "#omachee" }]
    .concat(directTargets.map(function(target) { return { value: target, label: "DM · " + target } }))
  readonly property var userOptions: users.filter(function(user) {
    return user.toLowerCase() !== nickname.toLowerCase()
  }).map(function(user) { return { value: user, label: user } })

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function appendEvent(kind, nick, text, target, own) {
    var conversation = String(target || "#omachee")
    if (!own && nick !== "" && isMuted(nick)) return
    if (conversation !== "#omachee") addDirectTarget(conversation)
    timeline.append({ kind: String(kind), nick: String(nick || ""),
      text: String(text || ""), target: conversation, own: !!own,
      stamp: Qt.formatTime(new Date(), "HH:mm"), sequence: sequence++ })
    if (timeline.count > 500) timeline.remove(0, timeline.count - 500)
    if (!opened && (kind === "message" || kind === "action")) unreadCount++
    Qt.callLater(function() { messageList.positionViewAtEnd() })
  }

  function addDirectTarget(target) {
    var value = String(target || "").trim()
    if (value === "" || value === "#omachee" || directTargets.indexOf(value) >= 0) return
    directTargets = directTargets.concat([value])
  }

  function openDirectMessage(target) {
    var value = String(target || selectedUser || "").trim()
    if (value === "" || value.toLowerCase() === nickname.toLowerCase()) return
    addDirectTarget(value)
    activeTarget = value
    selectedUser = value
    conversationDropdown.value = value
    Qt.callLater(function() { composer.forceActiveFocus() })
  }

  function isMuted(user) {
    return !!mutedUsers[String(user || "").toLowerCase()]
  }

  function toggleMute(user) {
    var value = String(user || selectedUser || "").trim()
    if (value === "" || value.toLowerCase() === nickname.toLowerCase()) return
    var next = Object.assign({}, mutedUsers)
    var key = value.toLowerCase()
    if (next[key]) {
      delete next[key]
      statusMessage = "Unmuted " + value
    } else {
      next[key] = true
      statusMessage = "Muted " + value + " for this session"
    }
    mutedUsers = next
  }

  function applyNames(nextUsers) {
    var merged = users.slice()
    for (var i = 0; i < nextUsers.length; i++) {
      var user = String(nextUsers[i] || "")
      if (user !== "" && merged.indexOf(user) < 0) merged.push(user)
    }
    users = merged.sort(function(a, b) { return a.toLowerCase().localeCompare(b.toLowerCase()) })
    if (selectedUser === "" && userOptions.length > 0) selectedUser = userOptions[0].value
  }

  function sendCommand(payload) {
    if (!helperStarted || !helper.running) return
    helper.write(JSON.stringify(payload) + "\n")
  }

  function startHelper() {
    if (helperStarted && helper.running) return
    helperStarted = true
    helper.running = true
  }

  function connectWithNickname() {
    var value = nicknameField.text.trim()
    if (value === "") {
      statusMessage = "Enter a guest nickname"
      nicknameField.forceActiveFocus()
      return
    }
    nickname = value
    sendCommand({ command: joined ? "nickname" : "connect", nickname: value })
  }

  function sendMessage() {
    var text = composer.text
    if (!joined || text.trim() === "") return
    sendCommand({ command: "send", target: activeTarget, text: text })
    composer.text = ""
  }

  function openEmojiPicker() {
    if (!joined) return
    composer.forceActiveFocus()
    Qt.callLater(function() {
      Quickshell.execDetached(["omarchy-shell", "shell", "toggle", "omarchy.emojis"])
    })
  }

  function handleHelperLine(line) {
    var event
    try {
      event = JSON.parse(String(line || ""))
    } catch (exception) {
      statusMessage = "The IRC helper returned malformed data"
      return
    }
    if (!event || typeof event.event !== "string") return
    if (event.event === "status") {
      connectionState = String(event.state || "connecting")
      statusMessage = String(event.message || "Connecting")
    } else if (event.event === "connected") {
      joined = true
      connectionState = "connected"
      nickname = String(event.nickname || nickname)
      nicknameField.text = nickname
      statusMessage = "Joined #omachee on Libera.Chat"
      appendEvent("notice", "", "Connected as " + nickname, "#omachee", false)
    } else if (event.event === "disconnected") {
      joined = false
      connectionState = "disconnected"
      statusMessage = String(event.message || "Disconnected")
    } else if (event.event === "nickname") {
      nickname = String(event.nickname || nickname)
      nicknameField.text = nickname
      appendEvent("notice", "", String(event.message || "Nickname changed"), "#omachee", false)
    } else if (event.event === "message" || event.event === "action") {
      var target = String(event.target || "#omachee")
      appendEvent(event.event, event.nick, event.text, target, !!event.own)
      if (target !== "#omachee" && opened && !event.own) {
        activeTarget = target
        conversationDropdown.value = target
      }
    } else if (event.event === "notice") {
      appendEvent("notice", event.nick, event.text, "#omachee", false)
    } else if (event.event === "names") {
      applyNames(Array.isArray(event.users) ? event.users : [])
    } else if (event.event === "join") {
      applyNames([event.nick])
      appendEvent("notice", "", String(event.nick || "Someone") + " joined", "#omachee", false)
    } else if (event.event === "part") {
      users = users.filter(function(user) { return user.toLowerCase() !== String(event.nick || "").toLowerCase() })
      appendEvent("notice", "", String(event.nick || "Someone") + " left", "#omachee", false)
    } else if (event.event === "quit") {
      users = users.filter(function(user) { return user.toLowerCase() !== String(event.nick || "").toLowerCase() })
      appendEvent("notice", "", String(event.nick || "Someone") + " quit", "#omachee", false)
    } else if (event.event === "nick") {
      users = users.map(function(user) { return user === event.nick ? String(event.newNick) : user })
      appendEvent("notice", "", String(event.nick || "Someone") + " is now " + String(event.newNick || ""), "#omachee", false)
    } else if (event.event === "error") {
      statusMessage = String(event.message || "IRC error")
      appendEvent("error", "", statusMessage, activeTarget, false)
    }
  }

  onOpenedChanged: if (opened) {
    unreadCount = 0
    startHelper()
    Qt.callLater(function() {
      if (nickname === "") nicknameField.forceActiveFocus()
      else composer.forceActiveFocus()
    })
  }

  ListModel { id: timeline }

  Process {
    id: helper
    command: ["python3", root.helperPath]
    stdinEnabled: true
    stdout: SplitParser { onRead: function(line) { root.handleHelperLine(line) } }
    stderr: SplitParser {
      onRead: function(_line) { root.statusMessage = "IRC helper encountered an error" }
    }
    onExited: function(exitCode) {
      root.joined = false
      root.connectionState = "disconnected"
      if (root.helperStarted) root.statusMessage = exitCode === 0
        ? "IRC helper stopped" : "IRC helper exited unexpectedly"
    }
  }

  WidgetButton {
    id: button
    bar: root.bar
    text: ""
    keepSpace: true
    hasVisualContent: true
    labelVisible: false
    fixedWidth: root.barSize
    fixedHeight: root.barSize
    active: root.unreadCount > 0
    tooltipText: root.unreadCount > 0 ? root.unreadCount + " unread in #omachee"
      : (root.joined ? "#omachee - connected" : "Omarchy IRC - " + root.connectionState)
    onPressed: function(_button) { root.toggle() }

    Item {
      width: Style.space(20)
      height: Style.space(18)
      anchors.centerIn: parent

      Text {
        anchors.centerIn: parent
        text: ""
        color: root.unreadCount > 0 ? root.urgent : root.foreground
        font.family: Style.font.icon
        font.pixelSize: Style.font.title
      }
      Rectangle {
        width: Style.space(6)
        height: width
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        radius: width / 2
        color: root.joined ? Color.accent
          : (root.connectionState === "reconnecting" || root.connectionState === "connecting"
            ? "#d9a441" : root.dim)
      }
      Rectangle {
        visible: root.unreadCount > 0
        anchors.right: parent.right
        anchors.top: parent.top
        width: Math.max(Style.space(12), unreadLabel.implicitWidth + Style.space(4))
        height: Style.space(12)
        radius: height / 2
        color: root.urgent
        Text {
          id: unreadLabel
          anchors.centerIn: parent
          text: root.unreadCount > 99 ? "99+" : String(root.unreadCount)
          color: Color.background
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(430))
    contentHeight: panel.fittedContentHeight(Style.space(560), Style.space(680))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: nicknameField.activeFocus || composer.activeFocus || directUserDropdown.popupOpen
        || conversationDropdown.popupOpen
      onCloseRequested: root.close()

      Column {
        anchors.fill: parent
        spacing: Style.space(9)

        Row {
          width: parent.width
          spacing: Style.space(8)
          Text {
            text: ""
            color: root.joined ? Color.accent : root.foreground
            font.family: Style.font.icon
            font.pixelSize: Style.font.display
          }
          Column {
            width: parent.width - Style.space(50)
            Text {
              width: parent.width
              text: "#omachee · Libera.Chat"
              textFormat: Text.PlainText
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }
            Text {
              width: parent.width
              text: root.statusMessage
              textFormat: Text.PlainText
              color: root.connectionState === "connected" ? Color.accent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(6)
          Dropdown {
            id: conversationDropdown
            width: parent.width * 0.45
            showLabel: false
            value: root.activeTarget
            options: root.conversationOptions
            foreground: root.foreground
            fontFamily: root.fontFamily
            onChanged: function(value) {
              root.activeTarget = value
              Qt.callLater(function() { composer.forceActiveFocus() })
            }
          }
          Dropdown {
            id: directUserDropdown
            width: parent.width - conversationDropdown.width - directButton.width
              - muteButton.width - parent.spacing * 3
            showLabel: false
            value: root.selectedUser
            options: root.userOptions
            foreground: root.foreground
            fontFamily: root.fontFamily
            onChanged: function(value) { root.selectedUser = value }
          }
          Button {
            id: directButton
            text: "DM"
            bordered: true
            enabled: root.selectedUser !== ""
            foreground: root.foreground
            onClicked: root.openDirectMessage(root.selectedUser)
          }
          Button {
            id: muteButton
            text: root.isMuted(root.selectedUser) ? "Unmute" : "Mute"
            bordered: true
            enabled: root.selectedUser !== ""
            foreground: root.foreground
            onClicked: root.toggleMute(root.selectedUser)
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(6)
          TextField {
            id: nicknameField
            width: parent.width - applyNickButton.width - parent.spacing
            text: root.nickname
            placeholderText: "Guest nickname"
            maximumLength: 16
            foreground: root.foreground
            onAccepted: root.connectWithNickname()
          }
          Button {
            id: applyNickButton
            text: root.joined ? "Change" : "Join"
            bordered: true
            active: !root.joined
            foreground: root.foreground
            onClicked: root.connectWithNickname()
          }
        }

        Rectangle {
          width: parent.width
          height: Math.max(Style.space(270), parent.height - Style.space(210))
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.035)
          border.width: Math.max(1, Style.spaceReal(1))
          border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.16)
          radius: Style.cornerRadius
          clip: true

          ListView {
            id: messageList
            anchors.fill: parent
            anchors.margins: Style.space(8)
            model: timeline
            spacing: Style.space(6)
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

            delegate: Item {
              required property string kind
              required property string nick
              required property string text
              required property string target
              required property bool own
              required property string stamp
              visible: target === root.activeTarget
              width: messageList.width - Style.space(8)
              height: visible ? messageText.implicitHeight : 0

              Text {
                id: messageText
                width: parent.width
                text: parent.kind === "message"
                  ? parent.nick + "  " + parent.text
                  : (parent.kind === "action" ? "* " + parent.nick + " " + parent.text : parent.text)
                textFormat: Text.PlainText
                color: parent.kind === "error" ? root.urgent
                  : (parent.kind === "notice" ? root.dim : root.foreground)
                font.family: root.fontFamily
                font.pixelSize: parent.kind === "notice" ? Style.font.caption : Style.font.body
                wrapMode: Text.Wrap
              }
            }

            Text {
              anchors.centerIn: parent
              visible: timeline.count === 0
              text: root.joined ? "No messages yet" : "Choose a nickname and join #omachee"
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(6)
          TextField {
            id: composer
            width: parent.width - emojiButton.width - sendButton.width - parent.spacing * 2
            enabled: root.joined
            placeholderText: root.joined ? "Message " + root.activeTarget : "Connect to send a message"
            foreground: root.foreground
            onAccepted: root.sendMessage()
          }
          Button {
            id: emojiButton
            text: "Emoji"
            iconText: ""
            bordered: true
            enabled: root.joined
            foreground: root.foreground
            tooltipText: "Open Omarchy emoji picker"
            onClicked: root.openEmojiPicker()
          }
          Button {
            id: sendButton
            text: "Send"
            bordered: true
            active: root.joined
            enabled: root.joined && composer.text.trim() !== ""
            foreground: root.foreground
            onClicked: root.sendMessage()
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(6)
          Text {
            width: parent.width - leaveButton.width - parent.spacing
            anchors.verticalCenter: parent.verticalCenter
            text: "Session-only chat · plain text · no account credentials"
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
          Button {
            id: leaveButton
            text: "Leave"
            bordered: true
            enabled: root.joined
            foreground: root.foreground
            onClicked: root.sendCommand({ command: "part" })
          }
        }
      }
    }
  }
}
