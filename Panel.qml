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
  readonly property int maxTimelineEntries: Math.max(100,
    Number(setting("maxTimelineEntries", 500)))
  readonly property int maxDirectTargets: 100
  readonly property string helperPath: decodeURIComponent(String(Qt.resolvedUrl("irc_helper.py")))
    .replace(/^file:\/\//, "")
  property string connectionState: "disconnected"
  property string statusMessage: "Choose a guest nickname to join"
  property string nickname: ""
  property string account: ""
  property int unreadCount: 0
  property bool helperStarted: false
  property bool joined: false
  property bool nicknameEditorOpen: false
  property bool nickServLoginOpen: false
  property int sequence: 0
  property string activeTab: "chat"
  property string activeTarget: "#omachee"
  property string lastDirectTarget: ""
  property string selectedUser: ""
  property string userQuery: ""
  property var users: []
  property var knownUsers: ({})
  property var operators: ({})
  property var directTargets: []
  property var mutedUsers: ({})
  property int actionSequence: -1
  property bool messageTextFocused: false
  property int commandSuggestionIndex: 0
  property bool commandSuggestionsDismissed: false
  property bool moderationConfirmOpen: false
  property string moderationAction: ""
  property string moderationTarget: ""
  readonly property bool currentUserOperator: isOperator(nickname)
  readonly property var kiwiEmoticons: ({
    ":)": "🙂", ":-)": "🙂", "=)": "🙂", ":]": "🙂",
    ":D": "😃", ":-D": "😃", "=D": "😃", "XD": "😆",
    ";)": "😉", ";-)": "😉", ";D": "😉",
    ":(": "😞", ":-(": "😞", "=(": "😞", ":'(": "😢",
    ":P": "😛", ":p": "😛", ":-P": "😛", ":b": "😛",
    "8)": "😎", "8-)": "😎", "B)": "😎", "B-)": "😎",
    ":O": "😮", ":-O": "😮", "O_O": "😮",
    ":/": "😕", ":-/": "😕", ":\\": "😕",
    ":*": "😘", ":-*": "😘", ":$": "😳",
    "<3": "❤", "</3": "💔", "D:": "😨", "X)": "😵"
  })
  readonly property var conversationOptions: directTargets.map(function(target) {
    return { value: target, label: target }
  })
  readonly property var visibleUsers: {
    var query = userQuery.trim().toLowerCase()
    var output = []
    for (var i = 0; i < users.length && output.length < 250; i++) {
      var user = users[i]
      if (nickKey(user) === nickKey(nickname)) continue
      if (query !== "" && user.toLowerCase().indexOf(query) < 0) continue
      output.push({ value: user, label: user })
    }
    return output
  }
  readonly property int otherUserCount: users.filter(function(user) {
    return nickKey(user) !== nickKey(nickname)
  }).length
  readonly property var slashCommands: [
    { command: "msg", usage: "/msg", description: "Send a private message" },
    { command: "me", usage: "/me", description: "Send an IRC action" },
    { command: "action", usage: "/action", description: "Alias for /me" },
    { command: "dice", usage: "/dice", description: "Roll a die; optionally set sides" },
    { command: "query", usage: "/query", description: "Open a private conversation" },
    { command: "nick", usage: "/nick", description: "Change your nickname" },
    { command: "mute", usage: "/mute", description: "Mute a user for this session" },
    { command: "unmute", usage: "/unmute", description: "Unmute a user" },
    { command: "clear", usage: "/clear", description: "Clear the active conversation" },
    { command: "part", usage: "/part", description: "Leave #omachee" },
    { command: "quit", usage: "/quit", description: "Disconnect from Libera.Chat" },
    { command: "join", usage: "/join", description: "Show fixed-channel join state" },
    { command: "help", usage: "/help", description: "Show supported commands" }
  ]
  readonly property var commandSuggestions: {
    var text = String(composer.text || "")
    if (commandSuggestionsDismissed || text.charAt(0) !== "/"
        || text.indexOf("//") === 0 || /\s/.test(text)) return []
    var query = text.substring(1).toLowerCase()
    return slashCommands.filter(function(item) {
      return item.command.indexOf(query) === 0
    })
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function nickKey(value) {
    return String(value || "").toLowerCase()
      .replace(/\[/g, "{").replace(/\]/g, "}")
      .replace(/\\/g, "|").replace(/\^/g, "~")
  }

  function appendEvent(kind, nick, text, target, own) {
    var conversation = String(target || "#omachee")
    var shouldScroll = conversation === activeTarget && messageList.atYEnd
      && !messageTextFocused
    if (!own && nick !== "" && isMuted(nick)) return
    if (conversation !== "#omachee") addDirectTarget(conversation)
    var row = { kind: String(kind), nick: String(nick || ""),
      text: String(text || ""), target: conversation, own: !!own,
      stamp: Qt.formatTime(new Date(), "HH:mm"), sequence: sequence++ }
    timeline.append(row)
    if (conversation === activeTarget) visibleTimeline.append(row)
    while (timeline.count > maxTimelineEntries) {
      var removedSequence = timeline.get(0).sequence
      timeline.remove(0)
      for (var i = 0; i < visibleTimeline.count; i++) {
        if (visibleTimeline.get(i).sequence === removedSequence) {
          visibleTimeline.remove(i)
          break
        }
      }
    }
    if (!opened && (kind === "message" || kind === "action")) unreadCount++
    if (shouldScroll) Qt.callLater(function() { messageList.positionViewAtEnd() })
  }

  function rebuildVisibleTimeline() {
    visibleTimeline.clear()
    for (var i = 0; i < timeline.count; i++) {
      var row = timeline.get(i)
      if (row.target === activeTarget) visibleTimeline.append({
        kind: row.kind, nick: row.nick, text: row.text, target: row.target,
        own: row.own, stamp: row.stamp, sequence: row.sequence
      })
    }
    Qt.callLater(function() { messageList.positionViewAtEnd() })
  }

  function displayText(text) {
    return String(text || "").split(/(\s+)/).map(function(token) {
      return kiwiEmoticons[token] || token
    }).join("")
  }

  function addDirectTarget(target) {
    var value = String(target || "").trim()
    if (value === "" || nickKey(value) === nickKey("#omachee")) return
    for (var i = 0; i < directTargets.length; i++)
      if (nickKey(directTargets[i]) === nickKey(value)) return
    if (directTargets.length >= maxDirectTargets) return
    directTargets = directTargets.concat([value])
  }

  function canonicalNickname(value) {
    var key = nickKey(value)
    for (var i = 0; i < users.length; i++)
      if (nickKey(users[i]) === key) return users[i]
    for (var j = 0; j < directTargets.length; j++)
      if (nickKey(directTargets[j]) === key) return directTargets[j]
    return String(value || "")
  }

  function openDirectMessage(target) {
    var value = canonicalNickname(String(target || selectedUser || "").trim())
    if (!/^[A-Za-z\[\]\\`_^{|}][A-Za-z0-9\[\]\\`_^{|}-]{0,15}$/.test(value)
        || nickKey(value) === nickKey(nickname)
        || nickKey(value) === nickKey("#omachee")) {
      commandError("Choose a valid user nickname for a DM")
      return false
    }
    addDirectTarget(value)
    activeTarget = value
    lastDirectTarget = value
    activeTab = "dms"
    selectedUser = value
    conversationDropdown.value = value
    Qt.callLater(function() { composer.forceActiveFocus() })
    return true
  }

  function isMuted(user) {
    return !!mutedUsers[nickKey(user)]
  }

  function isOperator(user) {
    return !!operators[nickKey(user)]
  }

  function setOperator(user, enabled) {
    var next = Object.assign({}, operators)
    var key = nickKey(user)
    if (enabled) next[key] = true
    else delete next[key]
    operators = next
  }

  function requestModeration(action, user) {
    if (!currentUserOperator) return
    moderationAction = action
    moderationTarget = canonicalNickname(user)
    moderationConfirmOpen = true
    moderationConfirm.selectedIndex = 0
    actionSequence = -1
    keyCatcher.forceActiveFocus()
  }

  function confirmModeration() {
    var action = moderationAction
    var target = moderationTarget
    moderationConfirmOpen = false
    moderationAction = ""
    moderationTarget = ""
    if (action === "kick") sendCommand({ command: "kick", nickname: target,
      reason: "Removed by a channel operator" })
    else if (action === "ban") sendCommand({ command: "ban", nickname: target,
      reason: "Banned by a channel operator" })
  }

  function cancelModeration() {
    moderationConfirmOpen = false
    moderationAction = ""
    moderationTarget = ""
  }

  function toggleMute(user) {
    var value = String(user || selectedUser || "").trim()
    if (value === "" || nickKey(value) === nickKey(nickname)) return
    setMuted(value, !isMuted(value))
  }

  function setMuted(user, muted) {
    var value = String(user || "").trim()
    if (value === "" || nickKey(value) === nickKey(nickname)) return
    var next = Object.assign({}, mutedUsers)
    var key = nickKey(value)
    if (muted) next[key] = true
    else delete next[key]
    mutedUsers = next
    statusMessage = (muted ? "Muted " : "Unmuted ") + value
      + (muted ? " for this session" : "")
  }

  function selectMessageUser(sequence, user) {
    var value = String(user || "")
    if (value === "" || nickKey(value) === nickKey(nickname)) return
    selectedUser = value
    actionSequence = actionSequence === sequence ? -1 : sequence
  }

  function applyNames(nextUsers) {
    var merged = users.slice()
    var nextKnown = Object.assign({}, knownUsers)
    for (var i = 0; i < nextUsers.length; i++) {
      var user = String(nextUsers[i] || "")
      var key = nickKey(user)
      if (user !== "" && !nextKnown[key]) {
        nextKnown[key] = true
        merged.push(user)
      }
    }
    knownUsers = nextKnown
    users = merged.sort(function(a, b) { return a.toLowerCase().localeCompare(b.toLowerCase()) })
    if (selectedUser === "" && visibleUsers.length > 0) selectedUser = visibleUsers[0].value
  }

  function replaceNames(nextUsers) {
    users = []
    knownUsers = ({})
    selectedUser = ""
    applyNames(nextUsers)
  }

  function removeUser(user) {
    var key = nickKey(user)
    users = users.filter(function(candidate) { return nickKey(candidate) !== key })
    var nextKnown = Object.assign({}, knownUsers)
    delete nextKnown[key]
    knownUsers = nextKnown
    setOperator(user, false)
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
    if (joined) {
      sendCommand({ command: "nickname", nickname: value })
    } else {
      var password = nickServLoginOpen ? passwordField.text : ""
      sendCommand({ command: "connect", nickname: value, account: value, password: password })
      passwordField.text = ""
    }
  }

  function sendMessage() {
    var text = composer.text
    if (!joined || text.trim() === "") return
    var submitted = text.indexOf("//") === 0
      ? sendText("send", activeTarget, text.substring(1))
      : (text.charAt(0) === "/" ? handleSlashCommand(text)
        : sendText("send", activeTarget, text))
    if (submitted) composer.text = ""
  }

  function sendText(command, target, text) {
    var normalized = String(text || "")
      .replace(/[ \t]*(?:\r\n?|\n)+[ \t]*/g, "\u2028").trim()
    if (normalized === "") return false
    sendCommand({ command: command, target: target, text: normalized })
    return true
  }

  function selectTab(tab) {
    activeTab = tab
    actionSequence = -1
    if (tab === "chat") activeTarget = "#omachee"
    else if (tab === "dms")
      activeTarget = lastDirectTarget !== "" ? lastDirectTarget
        : (directTargets.length > 0 ? directTargets[0] : "")
    Qt.callLater(function() {
      if ((tab === "chat" || tab === "dms") && root.joined && root.activeTarget !== "")
        composer.forceActiveFocus()
      else keyCatcher.forceActiveFocus()
    })
  }

  function clearActiveConversation() {
    for (var i = timeline.count - 1; i >= 0; i--)
      if (timeline.get(i).target === activeTarget) timeline.remove(i)
    rebuildVisibleTimeline()
  }

  function commandError(message) {
    statusMessage = message
    appendEvent("error", "", message, activeTarget || "#omachee", false)
    return false
  }

  function moveCommandSuggestion(delta) {
    if (commandSuggestions.length === 0) return
    commandSuggestionIndex = (commandSuggestionIndex + delta
      + commandSuggestions.length) % commandSuggestions.length
    commandSuggestionList.positionViewAtIndex(commandSuggestionIndex, ListView.Contain)
  }

  function applyCommandSuggestion(index) {
    if (index < 0 || index >= commandSuggestions.length) return
    composer.text = "/" + commandSuggestions[index].command + " "
    composer.cursorPosition = composer.text.length
    commandSuggestionsDismissed = true
    composer.forceActiveFocus()
  }

  function handleSlashCommand(input) {
    var parsed = String(input || "").match(/^\/(\S+)(?:\s+([\s\S]*))?$/)
    if (!parsed) return commandError("Invalid slash command. Use /help")
    var command = parsed[1].toLowerCase()
    var args = String(parsed[2] || "").trim()
    if (command === "me" || command === "action") {
      if (args === "") return commandError("Usage: /me action")
      return sendText("action", activeTarget, args)
    } else if (command === "dice") {
      var digits = args.replace(/\D/g, "")
      var sides = parseInt(digits === "" ? "6" : digits, 10)
      if (!Number.isFinite(sides) || sides <= 0) sides = 6
      if (sides > 1000000) return commandError("Dice may have at most 1,000,000 sides")
      var result = Math.floor(Math.random() * sides) + 1
      return sendText("action", activeTarget,
        "rolls a " + sides + "-sided die and gets " + result)
    } else if (command === "msg") {
      var direct = args.match(/^(\S+)(?:\s+([\s\S]*))?$/)
      if (!direct) return commandError("Usage: /msg nickname message")
      var target = direct[1]
      var message = String(direct[2] || "").trim()
      if (!openDirectMessage(target)) return false
      return message === "" ? true : sendText("send", target, message)
    } else if (command === "query") {
      if (args === "") return commandError("Usage: /query nickname")
      return openDirectMessage(args.split(/\s+/)[0])
    } else if (command === "nick") {
      if (args === "") return commandError("Usage: /nick nickname")
      nicknameField.text = args.split(/\s+/)[0]
      connectWithNickname()
      return true
    } else if (command === "mute" || command === "unmute") {
      if (args === "") return commandError("Usage: /" + command + " nickname")
      setMuted(args.split(/\s+/)[0], command === "mute")
      return true
    } else if (command === "clear") {
      clearActiveConversation()
      return true
    } else if (command === "part" || command === "quit") {
      sendCommand({ command: "part" })
      return true
    } else if (command === "join" && args.toLowerCase() === "#omachee") {
      statusMessage = joined ? "Already joined #omachee" : "Choose a nickname and use Join"
      return true
    } else if (command === "help") {
      appendEvent("notice", "", "Commands: /me, /action, /dice, /msg, /query, /nick, /mute, /unmute, /clear, /part, /quit, /join #omachee, /help", activeTarget || "#omachee", false)
      return true
    } else {
      return commandError("Unknown command /" + command + ". Use /help")
    }
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
      nicknameEditorOpen = false
      nickServLoginOpen = false
      connectionState = "connected"
      nickname = String(event.nickname || nickname)
      account = String(event.account || "")
      nicknameField.text = nickname
      statusMessage = account === "" ? "Joined #omachee on Libera.Chat"
        : "Identified as " + account + "; joined #omachee"
      appendEvent("notice", "", "Connected as " + nickname, "#omachee", false)
    } else if (event.event === "disconnected") {
      joined = false
      account = ""
      operators = ({})
      nicknameEditorOpen = false
      connectionState = "disconnected"
      statusMessage = String(event.message || "Disconnected")
    } else if (event.event === "nickname") {
      var previousNickname = nickname
      nickname = String(event.nickname || nickname)
      nicknameField.text = nickname
      nicknameEditorOpen = false
      if (previousNickname !== "" && nickKey(previousNickname) !== nickKey(nickname)) {
        removeUser(previousNickname)
        applyNames([nickname])
      }
      appendEvent("notice", "", String(event.message || "Nickname changed"), "#omachee", false)
    } else if (event.event === "message" || event.event === "action") {
      var target = String(event.target || "#omachee")
      if (nickKey(target) !== nickKey("#omachee")) target = canonicalNickname(target)
      appendEvent(event.event, event.nick, event.text, target, !!event.own)
      if (target !== "#omachee" && activeTab === "dms" && activeTarget === "")
        activeTarget = target
    } else if (event.event === "notice") {
      appendEvent("notice", event.nick, event.text, "#omachee", false)
    } else if (event.event === "names") {
      replaceNames(Array.isArray(event.users) ? event.users : [])
      operators = ({})
      var nextOperators = Array.isArray(event.operators) ? event.operators : []
      for (var i = 0; i < nextOperators.length; i++) setOperator(nextOperators[i], true)
    } else if (event.event === "operator") {
      setOperator(event.nick, !!event.operator)
    } else if (event.event === "join") {
      applyNames([event.nick])
      appendEvent("notice", "", String(event.nick || "Someone") + " joined", "#omachee", false)
    } else if (event.event === "part") {
      removeUser(event.nick)
      appendEvent("notice", "", String(event.nick || "Someone") + " left", "#omachee", false)
    } else if (event.event === "quit") {
      removeUser(event.nick)
      appendEvent("notice", "", String(event.nick || "Someone") + " quit", "#omachee", false)
    } else if (event.event === "kick") {
      removeUser(event.nick)
      if (event.own) {
        joined = false
        operators = ({})
        statusMessage = "Kicked from #omachee by " + String(event.by || "an operator")
      }
      appendEvent("notice", "", String(event.nick || "Someone") + " was kicked by "
        + String(event.by || "an operator") + (event.reason ? ": " + event.reason : ""),
        "#omachee", false)
    } else if (event.event === "nick") {
      removeUser(event.nick)
      applyNames([event.newNick])
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
      else if ((activeTab === "chat" || activeTab === "dms") && activeTarget !== "")
        composer.forceActiveFocus()
      else keyCatcher.forceActiveFocus()
    })
  }

  onActiveTargetChanged: rebuildVisibleTimeline()

  Component.onDestruction: {
    if (helper.running) helper.running = false
  }

  ListModel { id: timeline }
  ListModel { id: visibleTimeline }

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
      blocked: !root.moderationConfirmOpen && (nicknameField.activeFocus
        || passwordField.activeFocus || composer.activeFocus || userSearchField.activeFocus
        || conversationDropdown.popupOpen || root.messageTextFocused)
      onCloseRequested: root.moderationConfirmOpen ? root.cancelModeration() : root.close()
      onMoveRequested: function(dx, _dy) {
        if (root.moderationConfirmOpen && dx !== 0)
          moderationConfirm.selectedIndex = moderationConfirm.selectedIndex === 0 ? 1 : 0
      }
      onTabRequested: function(_direction) {
        if (root.moderationConfirmOpen)
          moderationConfirm.selectedIndex = moderationConfirm.selectedIndex === 0 ? 1 : 0
      }
      onActivateRequested: if (root.moderationConfirmOpen) {
        if (moderationConfirm.selectedIndex === 0) root.cancelModeration()
        else root.confirmModeration()
      }

      Column {
        anchors.fill: parent
        spacing: Style.space(9)

        Row {
          width: parent.width
          spacing: Style.space(8)
          Text {
            id: headerIcon
            text: ""
            color: root.joined ? Color.accent : root.foreground
            font.family: Style.font.icon
            font.pixelSize: Style.font.display
          }
          Column {
            width: parent.width - headerIcon.width - headerLeaveButton.width
              - (headerNicknameButton.visible ? headerNicknameButton.width : 0)
              - parent.spacing * (headerNicknameButton.visible ? 3 : 2)
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
          Button {
            id: headerNicknameButton
            visible: root.joined
            anchors.verticalCenter: parent.verticalCenter
            text: root.nickname
            iconText: ""
            bordered: true
            selected: root.nicknameEditorOpen
            foreground: root.foreground
            tooltipText: "Nickname options"
            onClicked: {
              root.nicknameEditorOpen = !root.nicknameEditorOpen
              if (root.nicknameEditorOpen) {
                nicknameField.text = root.nickname
                Qt.callLater(function() { nicknameField.forceActiveFocus() })
              }
            }
          }
          Button {
            id: headerLeaveButton
            anchors.verticalCenter: parent.verticalCenter
            text: ""
            iconText: ""
            bordered: true
            enabled: root.joined
            foreground: root.foreground
            tooltipText: "Leave #omachee"
            onClicked: root.sendCommand({ command: "part" })
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(6)
          Button {
            width: (parent.width - parent.spacing * 2) / 3
            text: "Chat"
            iconText: ""
            bordered: true
            selected: root.activeTab === "chat"
            foreground: root.foreground
            onClicked: root.selectTab("chat")
          }
          Button {
            width: (parent.width - parent.spacing * 2) / 3
            text: "Users"
            iconText: ""
            bordered: true
            selected: root.activeTab === "users"
            foreground: root.foreground
            onClicked: root.selectTab("users")
          }
          Button {
            width: (parent.width - parent.spacing * 2) / 3
            text: "DMs" + (root.directTargets.length > 0 ? " " + root.directTargets.length : "")
            iconText: ""
            bordered: true
            selected: root.activeTab === "dms"
            foreground: root.foreground
            onClicked: root.selectTab("dms")
          }
        }

        Row {
          id: nicknameRow
          visible: !root.joined || root.nicknameEditorOpen
          width: parent.width
          height: Style.space(40)
          spacing: Style.space(6)
          TextField {
            id: nicknameField
            height: parent.height
            width: parent.width - applyNickButton.width
              - (nickServModeButton.visible ? nickServModeButton.width + parent.spacing : 0)
              - (cancelNickButton.visible ? cancelNickButton.width + parent.spacing : 0)
              - parent.spacing
            text: root.nickname
            placeholderText: root.nickServLoginOpen ? "NickServ account" : "Guest nickname"
            maximumLength: 16
            foreground: root.foreground
            onAccepted: root.connectWithNickname()
          }
          Button {
            id: nickServModeButton
            visible: !root.joined
            height: parent.height
            text: ""
            iconText: ""
            bordered: true
            selected: root.nickServLoginOpen
            foreground: root.foreground
            tooltipText: root.nickServLoginOpen ? "Use a guest nickname"
              : "Use a registered NickServ account"
            onClicked: {
              root.nickServLoginOpen = !root.nickServLoginOpen
              passwordField.text = ""
              Qt.callLater(function() {
                if (root.nickServLoginOpen) passwordField.forceActiveFocus()
                else nicknameField.forceActiveFocus()
              })
            }
          }
          Button {
            id: applyNickButton
            height: parent.height
            text: root.joined ? "Apply" : "Join"
            bordered: true
            active: !root.joined
            foreground: root.foreground
            onClicked: root.connectWithNickname()
          }
          Button {
            id: cancelNickButton
            visible: root.joined
            height: parent.height
            text: "Cancel"
            bordered: true
            foreground: root.foreground
            onClicked: {
              root.nicknameEditorOpen = false
              nicknameField.text = root.nickname
              keyCatcher.forceActiveFocus()
            }
          }
        }

        Row {
          id: nickServRow
          visible: !root.joined && root.nickServLoginOpen
          width: parent.width
          TextField {
            id: passwordField
            width: parent.width
            placeholderText: "NickServ password (session only)"
            password: true
            foreground: root.foreground
            onAccepted: root.connectWithNickname()
          }
        }

        Dropdown {
          id: conversationDropdown
          visible: root.activeTab === "dms" && root.directTargets.length > 0
          width: parent.width
          showLabel: false
          value: root.activeTarget
          options: root.conversationOptions
          foreground: root.foreground
          fontFamily: root.fontFamily
          onChanged: function(value) {
            root.activeTarget = value
            root.lastDirectTarget = value
            Qt.callLater(function() { composer.forceActiveFocus() })
          }
        }

        Row {
          visible: root.activeTab === "users"
          width: parent.width
          spacing: Style.space(6)

          TextField {
            id: userSearchField
            width: parent.width - userCountLabel.width - parent.spacing
            placeholderText: "Search users"
            text: root.userQuery
            foreground: root.foreground
            onTextChanged: root.userQuery = text
          }
          Text {
            id: userCountLabel
            anchors.verticalCenter: parent.verticalCenter
            text: root.visibleUsers.length + " shown · " + root.otherUserCount + " total"
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Rectangle {
          visible: root.activeTab === "users"
          width: parent.width
          height: Math.max(Style.space(270), parent.height - Style.space(166)
            - (nicknameRow.visible ? nicknameRow.height + Style.space(9) : 0)
            - (nickServRow.visible ? nickServRow.height + Style.space(9) : 0))
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.035)
          border.width: Math.max(1, Style.spaceReal(1))
          border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.16)
          radius: Style.cornerRadius
          clip: true

          ListView {
            id: userList
            anchors.fill: parent
            anchors.margins: Style.space(8)
            model: root.visibleUsers
            spacing: Style.space(5)
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

            delegate: Rectangle {
              required property var modelData
              width: userList.width - Style.space(8)
              height: root.currentUserOperator ? Style.space(72) : Style.space(38)
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.035)
              radius: Style.cornerRadius

              Item {
                id: primaryUserRow
                width: parent.width
                height: Style.space(38)

                Text {
                  anchors.left: parent.left
                  anchors.right: root.currentUserOperator ? parent.right : userDmButton.left
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(8)
                  anchors.rightMargin: Style.space(8)
                  text: (root.isOperator(modelData.value) ? "@" : "") + modelData.label
                  textFormat: Text.PlainText
                  color: root.isMuted(modelData.value) ? root.dim : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }
                Button {
                  id: userDmButton
                  visible: !root.currentUserOperator
                  anchors.right: userMuteButton.left
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.rightMargin: Style.space(5)
                  text: "DM"
                  iconText: ""
                  bordered: true
                  foreground: root.foreground
                  onClicked: root.openDirectMessage(modelData.value)
                }
                Button {
                  id: userMuteButton
                  visible: !root.currentUserOperator
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.rightMargin: Style.space(5)
                  text: root.isMuted(modelData.value) ? "Unmute" : "Mute"
                  bordered: true
                  foreground: root.foreground
                  onClicked: root.toggleMute(modelData.value)
                }
              }
              Row {
                id: moderationActions
                readonly property int actionWidth: Math.floor(
                  (width - spacing * 3) / 4)
                visible: root.currentUserOperator
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.leftMargin: Style.space(5)
                anchors.rightMargin: Style.space(5)
                anchors.bottomMargin: Style.space(5)
                spacing: Style.space(5)

                Button {
                  width: moderationActions.actionWidth
                  text: "DM"
                  bordered: true
                  foreground: root.foreground
                  onClicked: root.openDirectMessage(modelData.value)
                }
                Button {
                  width: moderationActions.actionWidth
                  text: root.isMuted(modelData.value) ? "Unmute" : "Mute"
                  bordered: true
                  foreground: root.foreground
                  onClicked: root.toggleMute(modelData.value)
                }
                Button {
                  width: moderationActions.actionWidth
                  text: "Kick"
                  bordered: true
                  foreground: root.foreground
                  onClicked: root.requestModeration("kick", modelData.value)
                }
                Button {
                  width: moderationActions.actionWidth
                  text: "Ban"
                  bordered: true
                  foreground: root.urgent
                  tooltipText: "Ban and remove from #omachee"
                  onClicked: root.requestModeration("ban", modelData.value)
                }
              }
            }

            Text {
              anchors.centerIn: parent
              visible: root.visibleUsers.length === 0
              text: root.joined ? (root.userQuery === "" ? "No other users are currently visible"
                : "No users match this search") : "Join to load users"
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }
        }

        Rectangle {
          id: timelineSurface
          visible: root.activeTab === "chat" || root.activeTab === "dms"
          x: Math.max(1, Style.spaceReal(1))
          width: parent.width - x * 2
          height: Math.max(Style.space(190), parent.height
            - Style.space(root.activeTab === "dms" && root.directTargets.length > 0 ? 171 : 136)
            - (nicknameRow.visible ? nicknameRow.height + Style.space(9) : 0)
            - (nickServRow.visible ? nickServRow.height + Style.space(9) : 0)
            - Math.max(0, composerRow.height - Style.space(34)))
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.035)
          border.width: Math.max(1, Style.spaceReal(1))
          border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.16)
          radius: Style.cornerRadius
          clip: true

          ListView {
            id: messageList
            anchors.fill: parent
            anchors.margins: Style.space(8)
            model: visibleTimeline
            spacing: Style.space(6)
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

            delegate: Item {
              id: messageDelegate
              required property string kind
              required property string nick
              required property string text
              required property string target
              required property bool own
              required property string stamp
              required property int sequence
              readonly property bool hasSender: (kind === "message" || kind === "action")
                && nick !== ""
              readonly property bool actionsVisible: sequence === root.actionSequence
                && hasSender && root.nickKey(nick) !== root.nickKey(root.nickname)
              width: messageList.width - Style.space(8)
              height: messageColumn.implicitHeight

              Column {
                id: messageColumn
                width: parent.width
                spacing: messageDelegate.actionsVisible ? Style.space(4) : 0

                Column {
                  id: messageRow
                  width: parent.width
                  spacing: messageDelegate.hasSender ? Style.space(1) : 0

                  Button {
                    id: senderButton
                    visible: messageDelegate.hasSender
                    enabled: root.nickKey(messageDelegate.nick) !== root.nickKey(root.nickname)
                    text: (messageDelegate.kind === "action" ? "* " : "")
                      + messageDelegate.nick + ":"
                    bordered: false
                    active: messageDelegate.actionsVisible
                    foreground: Color.accent
                    fontFamily: root.fontFamily
                    horizontalPadding: Style.space(2)
                    verticalPadding: 0
                    onClicked: root.selectMessageUser(messageDelegate.sequence, messageDelegate.nick)
                  }

                  TextEdit {
                    id: messageText
                    width: messageRow.width
                    text: root.displayText(messageDelegate.text)
                    textFormat: TextEdit.PlainText
                    readOnly: true
                    selectByMouse: true
                    persistentSelection: true
                    color: messageDelegate.kind === "error" ? root.urgent
                      : (messageDelegate.kind === "notice" ? root.dim : root.foreground)
                    selectedTextColor: Color.background
                    selectionColor: Color.accent
                    font.family: root.fontFamily
                    font.pixelSize: messageDelegate.kind === "notice"
                      ? Style.font.caption : Style.font.body
                    wrapMode: TextEdit.Wrap
                    leftPadding: messageDelegate.hasSender ? Style.space(2) : 0
                    rightPadding: messageDelegate.hasSender ? Style.space(2) : 0
                    onActiveFocusChanged: root.messageTextFocused = activeFocus
                    Keys.onEscapePressed: function(event) {
                      deselect()
                      root.messageTextFocused = false
                      keyCatcher.forceActiveFocus()
                      event.accepted = true
                    }
                  }
                }

                Row {
                  id: senderActions
                  visible: messageDelegate.actionsVisible
                  height: visible ? implicitHeight : 0
                  spacing: Style.space(5)

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Actions for " + messageDelegate.nick
                    textFormat: Text.PlainText
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                  Button {
                    text: "DM"
                    iconText: ""
                    bordered: true
                    foreground: root.foreground
                    onClicked: {
                      root.actionSequence = -1
                      root.openDirectMessage(messageDelegate.nick)
                    }
                  }
                  Button {
                    text: root.isMuted(messageDelegate.nick) ? "Unmute" : "Mute"
                    iconText: root.isMuted(messageDelegate.nick) ? "" : ""
                    bordered: true
                    foreground: root.foreground
                    onClicked: root.toggleMute(messageDelegate.nick)
                  }
                }
              }
            }

            Text {
              anchors.centerIn: parent
              visible: visibleTimeline.count === 0
              text: !root.joined ? "Choose a nickname and join #omachee"
                : (root.activeTab === "dms" && root.activeTarget === ""
                  ? "Open a DM from the Users tab" : "No messages yet")
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }
        }

        Rectangle {
          id: commandSuggestionMenu
          parent: timelineSurface
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          anchors.margins: Style.space(8)
          z: 10
          visible: root.commandSuggestions.length > 0
          height: visible ? Math.min(Style.space(180),
            root.commandSuggestions.length * Style.space(30) + Style.space(4)) : 0
          color: Color.popups.background
          border.width: Math.max(1, Style.spaceReal(1))
          border.color: Color.popups.border
          radius: Style.cornerRadius
          clip: true

          ListView {
            id: commandSuggestionList
            anchors.fill: parent
            anchors.margins: Style.space(2)
            model: root.commandSuggestions
            currentIndex: root.commandSuggestionIndex
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

            delegate: Rectangle {
              required property var modelData
              required property int index
              width: commandSuggestionList.width
              height: Style.space(30)
              color: index === root.commandSuggestionIndex
                ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.22)
                : "transparent"

              Text {
                id: commandName
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(8)
                width: Style.space(115)
                text: modelData.usage
                textFormat: Text.PlainText
                color: index === root.commandSuggestionIndex ? Color.accent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                elide: Text.ElideRight
              }
              Text {
                anchors.left: commandName.right
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.rightMargin: Style.space(8)
                text: modelData.description
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.applyCommandSuggestion(index)
              }
            }
          }
        }

        Row {
          id: composerRow
          visible: (root.activeTab === "chat" || root.activeTab === "dms")
            && root.activeTarget !== ""
          x: Math.max(1, Style.spaceReal(1))
          width: parent.width - x * 2
          spacing: Style.space(6)
          Rectangle {
            id: composerFrame
            width: parent.width - emojiButton.width - sendButton.width - parent.spacing * 2
            height: Math.min(Style.space(78), Math.max(Style.space(34),
              composer.contentHeight + composer.topPadding + composer.bottomPadding))
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b,
              composer.activeFocus ? 0.08 : 0.035)
            border.width: Math.max(1, Style.spaceReal(1))
            border.color: composer.activeFocus ? Color.accent
              : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.2)
            radius: Style.cornerRadius
            clip: true

            QQC.ScrollView {
              id: composerScroll
              anchors.fill: parent
              anchors.margins: composerFrame.border.width
              clip: true
              QQC.ScrollBar.vertical.policy: QQC.ScrollBar.AsNeeded
              background: null

              QQC.TextArea {
                id: composer
                width: composerScroll.availableWidth
                height: Math.max(composerScroll.availableHeight,
                  contentHeight + topPadding + bottomPadding)
                enabled: root.joined
                placeholderText: root.joined ? "Message " + root.activeTarget + " · type / for commands"
                  : "Connect to send a message"
                color: root.foreground
                placeholderTextColor: root.dim
                selectionColor: Color.accent
                selectedTextColor: Color.background
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: TextEdit.Wrap
                leftPadding: Style.space(8)
                rightPadding: Style.space(8)
                topPadding: Style.space(6)
                bottomPadding: Style.space(6)
                background: null
                onTextChanged: {
                  root.commandSuggestionIndex = 0
                  root.commandSuggestionsDismissed = false
                }
                Keys.onPressed: function(event) {
                  if (commandSuggestionMenu.visible && event.key === Qt.Key_Down) {
                    root.moveCommandSuggestion(1)
                    event.accepted = true
                  } else if (commandSuggestionMenu.visible && event.key === Qt.Key_Up) {
                    root.moveCommandSuggestion(-1)
                    event.accepted = true
                  } else if (commandSuggestionMenu.visible
                      && (event.key === Qt.Key_Tab || event.key === Qt.Key_Return
                        || event.key === Qt.Key_Enter)) {
                    root.applyCommandSuggestion(root.commandSuggestionIndex)
                    event.accepted = true
                  } else if (commandSuggestionMenu.visible && event.key === Qt.Key_Escape) {
                    root.commandSuggestionsDismissed = true
                    event.accepted = true
                  } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                      && !(event.modifiers & (Qt.ShiftModifier | Qt.ControlModifier))) {
                    root.sendMessage()
                    event.accepted = true
                  }
                }
              }
            }
          }
          Button {
            id: emojiButton
            height: composerFrame.height
            text: ""
            iconText: ""
            bordered: true
            enabled: root.joined
            foreground: root.foreground
            tooltipText: "Open Omarchy emoji picker"
            onClicked: root.openEmojiPicker()
          }
          Button {
            id: sendButton
            height: composerFrame.height
            text: "Send"
            bordered: true
            active: root.joined
            enabled: root.joined && composer.text.trim() !== ""
            foreground: root.foreground
            onClicked: root.sendMessage()
          }
        }

      }

      ConfirmDialog {
        id: moderationConfirm
        anchors.fill: parent
        opened: root.moderationConfirmOpen
        z: 20
        message: root.moderationAction === "ban"
          ? "Ban " + root.moderationTarget + " and remove them from #omachee?\n\nReason: Banned by a channel operator"
          : "Remove " + root.moderationTarget + " from #omachee?\n\nReason: Removed by a channel operator"
        confirmText: root.moderationAction === "ban" ? "Ban" : "Kick"
        background: Color.popups.background
        foreground: root.foreground
        fontFamily: root.fontFamily
        onCanceled: root.cancelModeration()
        onConfirmed: root.confirmModeration()
      }
    }
  }
}
