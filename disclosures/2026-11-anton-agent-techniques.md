# Technical disclosure: driving a terminal AI coding agent from a phone

**Defensive publication.** Published 11 November 2026 by Samarth, author of Anton.
This document is published so that the techniques below are publicly available as
prior art. They are free for anyone to use; the author does not intend to patent them.

Anton lets a person drive an AI coding agent from a phone. The agent is an
interactive terminal program (for example Claude Code) running on the person's own
machine. A server on that machine, the Interactive Development Server (IDS), starts
each agent in a pseudo-terminal (PTY), streams it to a phone app, and talks to the
agent through the agent's hooks and a per-session local socket.

That setup raises three problems. This document describes how Anton solves each one.

1. [One live agent per conversation, across devices](#1-one-live-agent-per-conversation-across-devices)
2. [An approval gate that survives an intermittent phone](#2-an-approval-gate-that-survives-an-intermittent-phone)
3. [A command list the developer and the agent share](#3-a-command-list-the-developer-and-the-agent-share)
4. [Telling a running agent things without starting a turn](#4-telling-a-running-agent-things-without-starting-a-turn)
5. [Variations](#5-variations)

The behaviours described here shipped in public Anton releases between June and
October 2026.

---

## Background

**How the agent stores a conversation.** Each conversation is an append-only
transcript file named by a session ID (for Claude Code,
`~/.claude/projects/<encoded folder>/<session id>.jsonl`). Any new process can resume
it (`claude --resume <id>`). The conversation lives in the file, not in a process,
and nothing stops two processes resuming the same file at once.

**Problem 1: two live agents on one conversation.** A conversation started from the
phone may be resumed in a desktop terminal, or the other way round. Two processes on
one conversation append interleaved turns to one transcript, edit and commit in one
working tree at the same time, and leave the phone showing an old copy that never saw
prompts typed elsewhere. Terminal tools such as tmux, screen, SSH or VS Code Remote
share or reattach to a process; none of them knows that one conversation can live in
several processes, or checks whether a running copy has fallen behind its file.

**Problem 2: a human approval gate behind a fixed timeout.** Before risky actions the
agent asks permission through a hook, and the framework waits a fixed time for the
answer (600 seconds for Claude Code's `PermissionRequest` hook). After that it falls
back to its own prompt in the local terminal, which a person on a phone never sees, so
the session hangs. Phones sleep, lose signal and get closed, so missing the deadline
is normal. The model adds a second difficulty: a plain "denied" leads it to try
another way or abandon the task, and a plain "allowed" is unsafe without the human.

**Problem 3: what commands the agent may run.** Agents usually get a free shell, a
pattern-based allow-list inside the agent, or an approval prompt per command. Pattern
lists are hard to read and can be switched off by the agent's permission mode.
Per-command prompts make people approve the same action again and again until they
stop reading them.

---

## 1. One live agent per conversation, across devices

The server keeps exactly one live agent process per conversation as the person moves
between the phone, a terminal on the server, and another computer. Four mechanisms
work together; each covers a gap the others leave.

### 1A. Working out which live process holds which conversation

The server scans the process table once and works from that single snapshot.

- **Record ownership before filtering what to show.** Every agent process whose
  command line names a session ID records a claim on that ID, including processes the
  phone will never be offered, such as the server's own background turns. Not being
  shown is not the same as not owning.
- **Rank the claims.** A claim from an outside terminal outranks one from the server's
  own process: a terminal owns its conversation outright, while a conversation the
  server is running may have been reopened somewhere else.
- **Find the server's own processes by ancestry**, walking each process's parent chain
  against the server's own process IDs and service binaries.
- **Leave out headless one-shot runs** (`-p` / `--print`).
- **Attribute a process that names no session ID by its start time, not recency.** Its
  transcript is the unclaimed file that began closest after the process started.
  Processes are matched oldest first, so several in one folder each get their own file.
- **If the match is ambiguous, give no answer.** An older file being written now is
  the sign of a resumed session; it is accepted only when this is the only agent in
  that folder and exactly one such file is live. A missing entry costs a refresh; a
  wrong one would point the phone at someone else's conversation.
- **Tell the server's own session IDs apart by UUID version.** The server mints
  version-7 UUIDs and the agent mints version-4, so the ID itself records where it
  came from.

### 1B. Detecting that the server's own copy has fallen behind

The server keeps its agent copy running after the phone leaves. If the conversation
goes on in another process meanwhile, reattaching would show the phone a stale
conversation.

- A hook in the server's copy (`UserPromptSubmit`) reports every prompt that copy is
  handed, with the ID the agent will record it under, over the session socket.
- The server keeps a ledger of those prompts, and a file offset set to where the
  transcript ended when the copy started.
- When a device opens the session, the server reads only the complete lines appended
  since that offset, and matches each human-typed prompt against the ledger: by ID
  first, then by text for queued prompts the hook could not name.
- A human prompt in the transcript that was never reported must have been typed into a
  different process, so the copy is behind.
- Only prompts are compared. Replies and tool output follow from prompts, and the copy
  writes plenty of them with nobody watching.
- A copy whose hooks have never reported is never judged; otherwise every prompt would
  look foreign to it.

When the copy is behind, the server replaces it with a fresh resume of the transcript,
which holds everything. Safeguards:

- it never stops an outside terminal the person didn't ask it to;
- if the copy is mid-turn, running background tasks, or waiting on a question or
  approval, it asks the person before cutting it off;
- if the conversation is open in an identifiable terminal, it refuses and offers an
  explicit take-over instead;
- it replaces the copy under the same lock as every resume, so two devices opening at
  once don't both replace it.

### 1C. One device holds a session at a time

The server records which signed device holds each session's live connection.

- A reconnect from the same device replaces its old connection silently.
- Another device is refused (`session_held`) with the holder's name; the app shows
  "Open on iPhone · Continue here".
- An explicit take-over is accepted, and the previous device is told (`taken_over`)
  and disconnected.
- With no holder, any device attaches, so automatic reconnect still works.

### 1D. Explicit hand-off in both directions

**Phone to computer.** The phone asks for the hand-off. The server writes a hand-off
record, stops its own copy and waits for it to exit. On the computer, a CLI command
(`anton resume`) or a desktop notification resumes the conversation by its ID in its
original folder. A terminal that names its ID is one the server can always attribute,
so taking it back later is reliable. Before resuming, the computer checks that the
folder still exists, that no process holds the ID, and that no human prompt was
written after the hand-off (with a small slack for the stop). Such a prompt means the
conversation carried on somewhere the process check cannot see, so the hand-off is
out of date and is dropped.

**Terminal to phone.** A terminal process owns its PTY, so the live process cannot
change hands. Only when the person asks, the server stops it, waits a bounded time,
and resumes from the transcript. The agent writes the conversation as it goes, so
nothing is lost.

### Why the combination matters

Attribution (1A) cannot see a terminal opened from the agent's own session picker,
which names no ID. The ledger (1B) catches exactly that case after the fact. The
hand-off (1D) makes the common path name its ID, so 1A works. The device rule (1C)
stops two phones from becoming two writers by accident.

---

## 2. An approval gate that survives an intermittent phone

The server, not the agent framework, decides what happens when the person doesn't
answer in time. It turns that into a pause the model respects, and resumes the agent
later from any device. The approval path runs from the agent's permission hook, over
the per-session socket, to the server, and on to the phone.

### 2A. Three deadlines, nested so the server's comes first

| Deadline | Value |
|---|---|
| Server decides | 555 s |
| Hook's transport (curl `--max-time`) gives up | 570 s |
| Agent framework abandons the hook | 600 s |

The server always answers first, so the hook always returns a controlled response and
the framework never falls back to its terminal-only prompt. An answer within the
server's deadline goes straight back to the agent.

### 2B. A third outcome: deferred, sent as a refusal that means wait

When its deadline passes, the server returns neither allow nor deny but a distinct
*deferred* result. The hook turns it into a deny carrying an instruction for the model:

> APPROVAL_PAUSED: The user stepped away and hasn't responded yet. Do not retry, do
> not take an alternative approach, and do not end the task — stop and wait. You'll be
> told when to continue.

The model goes quiet instead of working around the block or giving up. This uses only
responses the framework already supports, with no change to the framework.

### 2C. The pending decision outlives the connection

- On deferral the server stores a resume card keyed to the request ID and pushes it
  to the phone.
- Cards are sent again to any device that attaches later, so a phone that was asleep
  or offline still sees them.
- A push notification goes out only if the approval is still pending after 25 s, so a
  phone that is attached and answers quickly is never pinged.
- A copy is never replaced (1B) while a card is waiting, unless the person agrees.

### 2D. Resuming by typing into the agent's live terminal

When the person taps approve or cancel, the server re-enters the agent by writing a
plain-language instruction into its PTY, as if typed:

- approve: "The user approved the previously paused action. Please proceed with it
  now and continue the task."
- cancel: "The user declined the previously paused action. Do not perform it;
  continue with the remaining work if possible, otherwise stop and summarize what is
  left."

No structured resume interface is needed, which keeps this independent of the agent.
A duplicate tap on an already-resolved card is dropped.

### 2E. Questions, and answers that arrive late

The agent can also ask the person a multiple-choice question through a tool, under
the same principle:

- The server's wait (4 h) is set below the tool timeout it configures (4 h 10 min),
  so the server ends the wait first with a "stop and wait" reply rather than an abort.
- After the tool call has ended, the question's card stays on the phone, marked
  orphaned. A later tap is typed into the session as a message instead.
- One lock decides whether an answer goes back as the tool's reply or later as a
  message, so an answer is always one or the other and never lost between them.

### 2F. Approval buttons that match the agent's own options

The phone's buttons come from the agent's own permission request. Each suggested
permission update, such as "don't ask again for `git init *`" or "allow all edits this
session", becomes its own button, and choosing it hands that exact update back to the
agent. "Switch to auto mode" is offered only when the session isn't already in it.

If the hook cannot reach the server at all, it currently allows the action so that a
dead server never hangs the agent. Failing closed (deny) or pausing are equally
possible.

---

## 3. A command list the developer and the agent share

Each project has a list of named commands (name, command, working folder, shell). The
developer runs entries and builds the list by hand in the app. The AI agent can run
the same entries and append to the list, under limits the server enforces. This gives:

- **Control.** The developer decides which commands the agent can run for a project
  or task. The list is the agent's whole command vocabulary for that work.
- **Transparency without repeated approvals.** A command is reviewed once, when it
  joins the list. After that the agent can run it as often as needed without asking,
  and every run is still visible as a named, live session the developer can open.

### 3A. One list, two kinds of user, different rights

| Action | Developer | Agent |
|---|---|---|
| Read the list | Yes | Yes (`list_build_commands`) |
| Run an entry | Yes, by tapping it | Yes, by name only (`run_build_command`); it can never pass command text |
| Add an entry | Yes | Only after the developer approves the exact command on the phone (`add_build_command`) |
| Edit or delete an entry | Yes | Never |

Because it is the same list the developer uses by hand, what the agent may run and
what the developer runs never drift apart.

### 3B. Limits enforced by the server, not by the agent

- The agent names an entry and the server looks up the command text. Text the agent
  supplies is never executed through this path.
- The approval to add an entry is asked by the server, as a question card showing the
  exact command, folder and shell. It does not rely on the agent's own permission
  hook, which may not fire in an automatic permission mode, so the rule holds whatever
  mode the agent runs in.
- A duplicate name is refused, and folders are validated as for the developer's own
  edits.
- Only the agent's own project is in scope; the project is derived from the session's
  working folder.
- Approved commands are remembered as suggestions for other projects.

### 3C. Every run is a live, watchable session

- A run the agent starts is an ordinary terminal session on the server, exactly as if
  the developer had tapped the command.
- The agent's session tells the attached phone, which shows a card ("AI is running
  *name*"); tapping it opens a live terminal on that run.
- Recent runs are re-sent to a device that attaches later, so a developer who wasn't
  watching still sees what ran. Dismissed cards stay dismissed across reconnects and
  devices.
- Commands that never finish, such as dev servers, are handled: a run waits a bounded
  time (up to 30 minutes), then returns its output so far and a run ID, and the agent
  checks back later (`check_build_run`).
- The agent receives output with terminal escape codes removed, capped at the last
  20 KB.

---

## 4. Telling a running agent things without starting a turn

The server tells a running agent about changes made from the phone without
interrupting it or starting a turn. It is used, for example, when the person switches
or renames the git branch under a session from the app.

- The server queues a note for every live agent session working inside the affected
  repository, keeping only the latest few.
- Hooks that run after every tool call (`PostToolUse`) and on every prompt
  (`UserPromptSubmit`) fetch pending notes from the session socket.
- The hook returns them as `additionalContext`, which the agent reads as context, not
  as a prompt. A busy agent learns of the change at its next tool call, an idle one
  with its next prompt.
- The hook has a 2-second limit, outputs nothing on any error, and passes on only a
  well-formed JSON string, so it never gets in the agent's way.

---

## 5. Variations

None of the above depends on Claude Code's particular file layout, flags or hook
names. Each technique applies equally with the following substitutions.

**Section 1**
- Agent: any conversational agent whose conversation lives in a resumable store — a
  file, a database row, or a server-side thread.
- Ownership signal: a session ID on the command line, an environment variable, an open
  file handle on the transcript, or a lock file.
- Process discovery: `/proc` on Linux, `ps` on macOS, or a container or remote-host
  process API.
- Stale-copy detection: compare any record of the inputs the copy was given (prompt
  IDs, content hashes, sequence numbers, vector clocks) against the store's inputs, or
  compare store versions where writes are versioned.
- Handling a stale copy: replace it with a fresh resume, refuse and offer a take-over,
  or warn and let the person choose.
- Devices: phones, tablets, browsers, desktop apps or other terminals, identified by a
  signed key, a session token or an account.
- Hand-off transport: a CLI command, a desktop notification, a deep link or a QR code,
  as long as it resumes by ID.

**Section 2**
- Deadlines: any ordering in which the intermediary's deadline is shorter than the
  framework's; the intermediary may also read the framework's timeout and derive its
  own from it.
- Expressing the pause: a deny with an instruction, an error result with an
  instruction, or a tool result asking the model to wait — any response the framework
  already supports, carrying a wait instruction.
- Resuming the agent: typing into its PTY, a message through a chat API, a hook's
  context injection, or a structured resume interface where one exists.
- Storing the pending decision: memory, a database, or a relay server.
- Who answers: any approver device, several approvers, or a delegate.
- Unreachable server: fail open, fail closed, or pause.

**Section 3**
- The list may be scoped to a project, a task, a ticket or a branch.
- Entries may carry parameters chosen from fixed values set by the developer, so the
  agent still never supplies free text.
- Approval of a new entry may happen on any device the developer uses, or by more than
  one approver.
- Runs may execute locally, in a container, or on a remote build host, as long as they
  are streamed as watchable sessions.
- The agent may reach the list through MCP tools, a local socket, an HTTP API, or any
  other tool interface.

**Section 4**
- Notes may describe any out-of-band change: branch switches, file changes made from
  another device, ticket updates, or messages from the person.
- Delivery may use any hook or callback that returns context to the agent without
  starting a turn.
