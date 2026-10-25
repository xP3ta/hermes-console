## Console 1.3.1

A stability and language release on top of 1.3.0. Console still talks only to the
Hermes Dashboard, and it now follows Hermes 0.22.4.

**Fixed**

- **Named profiles.** Chats of profiles with a name (for example `pi` or
  `social-writer`) open, show their history and keep new messages again. The false
  **Messages missing** warning no longer appears.
- **Attachments.** Sending a photo or file no longer asks for a confirmation of
  its own, as on Hermes Desktop. Read-only mode still blocks uploads.
- **Foldables and tablets.** In the medium-width layout, cancelling or accepting a
  dialog (delete a chat, YOLO) no longer closes the chat behind it.
- **Sign-in notice.** *Session expired · Sign in* no longer stays on screen after
  the connection comes back by itself. If the server refuses the one-time ticket of
  a new socket, Console asks for a fresh one once before it treats it as a problem.
- **Chat list.** A chat no longer stays on **Working…** after you close and reopen
  the app while its turn was running; the list reads the server again.
- **Chat list on return.** When the app comes back to the foreground, the list checks
  its live connections, so a turn that is running (even one started from another
  client) shows as **Working…** without opening the chat.
- **Chat stuck on Offline.** After a single refused ticket the chat reconnects by
  itself, or with Retry, instead of staying offline.
- **Startup recovery screen** follows the language of the device.

**Languages**

- The whole interface in nine languages: Spanish, English, German, French,
  Italian, Brazilian Portuguese, Japanese, Korean and Chinese. This includes
  notifications, the Android widgets and shortcut, schedules, relative times,
  error messages and voice controls and narration.
- Permission modes and generic chat titles (Kanban task, Scheduled task,
  Conversation) were still shown in Spanish in other languages; they now follow
  the app language.

**Hermes 0.22.4**

- Restoring a checkpoint lists the files it left untouched.
- A plugin update blocked by the security scan shows the verdict and findings.
- Provider limits are read from the model catalog when the session has none.
- Clear messages when a Hermes that runs behind the gateway withholds its
  session token.
- Bot Mode lists only the bots of the selected instance.

**Under the hood**

- The last Gateway code paths are gone; the chat, history and deletes use only
  the Dashboard.

**Thanks**

- Lucas Oliveira (@lucasliet) for the Brazilian Portuguese translation (#212).
- Rafael Telles (@rafael-telles) for localized session titles (#211).
