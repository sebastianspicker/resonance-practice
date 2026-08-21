"use strict";

const document = globalThis.document;

const presentationFixture = Object.freeze({
  course: "Mock University · Piano Studio I",
  student: "Lea Sommer",
  teacher: "Prof. Anna Berg",
  entries: [
    { key: "draft", goal: "Draft: octaves warmup pattern", detailGoal: "Octaves warmup pattern", date: "23 February 2026", duration: "6 min", notes: "Still experimenting with fingering.", status: "Draft" },
    { key: "submitted", goal: "Improve legato transitions in Chopin Nocturne", detailGoal: "Improve legato transitions in Chopin Nocturne", date: "20 February 2026", duration: "15 min", notes: "Left hand balance and softer pedal.", status: "Submitted" },
    { key: "reviewed", goal: "Phrase shaping in Debussy prelude", detailGoal: "Phrase shaping in Debussy prelude", date: "18 February 2026", duration: "14 min", notes: "Try broader dynamic contrast.", status: "Reviewed" },
  ],
  reviewQueue: [
    { key: "lea", student: "Lea Sommer", goal: "Improve legato transitions in Chopin Nocturne", date: "20 February 2026", duration: "15 min", notes: "Left hand balance and softer pedal.", status: "Submitted" },
    { key: "noah", student: "Noah Keller", goal: "Stabilize tempo in Bach invention, hands together", date: "21 February 2026", duration: "12 min", notes: "Focus on metronome consistency.", status: "Submitted" },
  ],
  feedback: {
    outcome: "Next goal",
    comments: "Great color palette. Next step: slower transitions before full tempo.",
    markers: [{ time: "00:18", text: "Excellent voicing here." }, { time: "00:41", text: "Keep wrist relaxed in this passage." }],
  },
});

const svgNamespace = "http://www.w3.org/2000/svg";
const icons = new Map([
  ["courses", [{ name: "path", attributes: { d: "M4 5.5A2.5 2.5 0 0 1 6.5 3H20v16H6.5A2.5 2.5 0 0 0 4 21.5zM4 5.5v16M8 7h8M8 11h8" } }]],
  ["entries", [{ name: "path", attributes: { d: "M6 3h9l3 3v15H6zM14 3v4h4M9 11h6M9 15h6" } }]],
  ["review", [{ name: "path", attributes: { d: "M4 5h16v14H4zM8 9h8M8 13h5" } }]],
  ["calendar", [{ name: "path", attributes: { d: "M4 6h16v14H4zM8 3v6M16 3v6M4 10h16" } }]],
  ["sync", [{ name: "path", attributes: { d: "M20 7h-5V2M4 17h5v5M19 12a7 7 0 0 0-12-5L4 10M5 12a7 7 0 0 0 12 5l3-3" } }]],
  ["settings", [{ name: "circle", attributes: { cx: "12", cy: "12", r: "3" } }, { name: "path", attributes: { d: "M19 12a7 7 0 0 0-.1-1l2-1.5-2-3.4-2.4 1A8 8 0 0 0 15 6.2L14.7 3h-4L10 6.2a8 8 0 0 0-1.5.9l-2.4-1-2 3.4L6.1 11a7 7 0 0 0 0 2l-2 1.5 2 3.4 2.4-1a8 8 0 0 0 1.5-.9l2.4 1 2-3.4-2-1.5a7 7 0 0 0 .1-1z" } }]],
]);

const state = {
  role: "student",
  view: "entries",
  selectedEntry: "draft",
  queued: false,
};

const roleConfigurations = new Map([
  ["student", { name: presentationFixture.student, label: "Student", waiting: "2 items waiting", queuedWaiting: "3 items waiting", detail: "One upload needs attention", items: [["entries", "Practice entries", "entries"], ["reviewed", "Reviewed feedback", "review"]] }],
  ["teacher", { name: presentationFixture.teacher, label: "Teacher", waiting: "Feedback queue ready", queuedWaiting: "Feedback queue ready", detail: "No command sent", items: [["review", "To review", "review"], ["reviewed-list", "Reviewed", "entries"]] }],
]);
const toolNavigationItems = [["calendar", "Calendar", "calendar"], ["sync", "Sync status", "sync"], ["settings", "Settings", "settings"]];

const contentPanel = document.querySelector("#content-panel");
const sidebarNav = document.querySelector("#sidebar-nav");
const personaName = document.querySelector("#persona-name");
const personaRole = document.querySelector("#persona-role");
const syncTitle = document.querySelector("#sync-title");
const syncDetail = document.querySelector("#sync-detail");

function element(name, { attributes = {}, className, text } = {}) {
  const node = document.createElement(name);
  if (className) {
    node.className = className;
  }
  if (text !== undefined) {
    node.textContent = text;
  }
  for (const [attribute, value] of Object.entries(attributes)) {
    node.setAttribute(attribute, value);
  }
  return node;
}

function append(parent, ...children) {
  parent.append(...children.filter(Boolean));
  return parent;
}

function icon(name) {
  const definitions = icons.get(name);
  const svg = document.createElementNS(svgNamespace, "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("aria-hidden", "true");
  for (const definition of definitions) {
    const child = document.createElementNS(svgNamespace, definition.name);
    for (const [attribute, value] of Object.entries(definition.attributes)) {
      child.setAttribute(attribute, value);
    }
    svg.append(child);
  }
  return svg;
}

function simulationTag() {
  return element("span", { className: "simulation-tag", text: "Simulated" });
}

function statusPill(status) {
  return element("span", {
    className: "status-pill status-" + status.toLowerCase(),
    text: status,
  });
}

function waveform() {
  const waveformNode = element("div", {
    className: "waveform",
    attributes: { "aria-hidden": "true" },
  });
  for (let index = 0; index < 9; index += 1) {
    waveformNode.append(element("span"));
  }
  return waveformNode;
}

function button(className, text, attributes = {}, simulated = false) {
  const node = element("button", {
    className,
    attributes: { type: "button", ...attributes },
  });
  node.append(document.createTextNode(text));
  if (simulated) {
    node.append(simulationTag());
  }
  return node;
}

function commandButton(text, command) {
  return button("command-button", text, { "data-command": command }, true);
}

function buttonRow(...buttons) {
  return append(element("div", { className: "button-row" }), ...buttons);
}

function markerNode(marker) {
  return append(
    element("div", { className: "feedback-marker" }),
    element("time", { text: marker.time }),
    element("p", { text: marker.text }),
  );
}

function metadataList(rows) {
  const list = element("dl", { className: "metadata-list" });
  for (const [label, value] of rows) {
    list.append(
      append(
        element("div"),
        element("dt", { text: label }),
        element("dd", { text: value }),
      ),
    );
  }
  return list;
}

function contentHeader(label, title, description, trailing) {
  const heading = append(
    element("div"),
    element("span", { className: "section-label", text: label }),
    element("h3", { text: title }),
    element("p", { text: description }),
  );
  return append(element("header", { className: "content-header" }), heading, trailing);
}

function mediaStage(primary, secondary, control) {
  return append(
    element("section", { className: "media-stage" }),
    waveform(),
    element("strong", { text: primary }),
    element("span", { className: "muted", text: secondary }),
    buttonRow(control),
  );
}

function entryRow(entry) {
  const status = entry.key === "draft" && state.queued ? "Queued" : entry.status;
  const leading = append(
    element("span"),
    element("strong", { text: entry.goal }),
    element("small", { text: entry.date + " · " + entry.duration }),
  );
  const meta = append(
    element("span", { className: "row-meta" }),
    statusPill(status),
    element("span", { className: "row-arrow", attributes: { "aria-hidden": "true" }, text: "›" }),
  );
  return append(
    button("entry-row", "", { "data-entry": entry.key }),
    leading,
    meta,
  );
}

function reviewRow(entry) {
  const leading = append(
    element("span"),
    element("strong", { text: entry.student }),
    element("small", { text: entry.goal + " · " + entry.date }),
  );
  const meta = append(
    element("span", { className: "row-meta" }),
    statusPill(entry.status),
    element("span", { className: "row-arrow", attributes: { "aria-hidden": "true" }, text: "›" }),
  );
  return append(button("entry-row", "", { "data-review": entry.key }), leading, meta);
}

function navigationButton(view, label, iconName, active) {
  return append(
    button("nav-button" + (active ? " is-active" : ""), "", { "data-view": view }),
    icon(iconName),
    element("span", { text: label }),
  );
}

function renderSidebar() {
  const role = roleConfigurations.get(state.role);
  personaName.textContent = role.name;
  personaRole.textContent = role.label + " · simulated session";
  syncTitle.textContent = state.queued ? role.queuedWaiting : role.waiting;
  syncDetail.textContent = role.detail;
  const navigation = [
    element("span", { className: "nav-section-label", text: presentationFixture.course }),
    ...role.items.map(([view, label, iconName]) => navigationButton(view, label, iconName, state.view === view)),
    element("span", { className: "nav-section-label", text: "Tools" }),
    ...toolNavigationItems.map(([view, label, iconName]) => navigationButton(view, label, iconName, false)),
  ];
  sidebarNav.replaceChildren(...navigation);
}

function renderStudentEntries() {
  const list = element("div", { className: "list-surface" });
  list.append(...presentationFixture.entries.map(entryRow));
  contentPanel.replaceChildren(
    contentHeader(
      "Student workspace",
      "Practice entries",
      "Evidence stays explicit from local draft through reviewed feedback.",
    ),
    list,
  );
}

function feedbackSection(entry) {
  const section = append(element("section", { className: "grouped-section" }), element("h4", { text: "Teacher feedback" }));
  if (entry.key === "reviewed") {
    section.append(element("p", { text: presentationFixture.feedback.comments }));
    section.append(...presentationFixture.feedback.markers.map(markerNode));
  } else {
    section.append(
      element("p", {
        className: "muted",
        text: "No feedback yet. Submit the entry so your teacher can review it.",
      }),
    );
  }
  return section;
}

function renderStudentDetail() {
  const entry = presentationFixture.entries.find((candidate) => candidate.key === state.selectedEntry);
  const status = entry.key === "draft" && state.queued ? "Queued" : entry.status;
  const controls = [
    entry.key === "draft" ? commandButton("Submit for review", "submit") : null,
    button("secondary-button", "Back to entries", { "data-view": "entries" }),
  ];
  const media = mediaStage(
    entry.key === "draft" ? "Practice audio not recorded" : "Practice audio · 01:05",
    entry.key === "draft"
      ? "Microphone access is never requested by this page."
      : "Playback is visual only in this static demo.",
    commandButton(entry.key === "draft" ? "Record audio" : "Play evidence", "play"),
  );
  const details = append(
    element("section", { className: "grouped-section" }),
    element("h4", { text: "Entry details" }),
    metadataList([
      ["Status", status],
      ["Reflection", entry.notes],
      ["Privacy", "Private course review"],
    ]),
  );
  const left = append(
    element("div"),
    media,
    buttonRow(...controls),
    element("p", {
      className: "simulation-disclosure",
      text: "Command-capable controls change this page's local display only. No recording, upload, submission, playback request, or sync command is sent.",
    }),
  );
  contentPanel.replaceChildren(
    contentHeader("Practice entry", entry.detailGoal, entry.date + " · " + entry.duration, statusPill(status)),
    append(element("div", { className: "detail-grid" }), left, append(element("div"), details, feedbackSection(entry))),
  );
}

function renderReviewedFeedback() {
  const entry = presentationFixture.entries.find((candidate) => candidate.key === "reviewed");
  const feedback = append(
    element("section", { className: "grouped-section" }),
    element("h4", { text: presentationFixture.feedback.outcome }),
    element("p", { text: presentationFixture.feedback.comments }),
    ...presentationFixture.feedback.markers.map(markerNode),
  );
  contentPanel.replaceChildren(
    contentHeader(
      "Student workspace",
      "Reviewed feedback",
      "Feedback is attached to the submitted practice evidence.",
      statusPill("Reviewed"),
    ),
    append(
      element("div", { className: "detail-grid" }),
      mediaStage(entry.detailGoal, "Practice audio · 01:12", commandButton("Play evidence", "play")),
      feedback,
    ),
    element("p", {
      className: "simulation-disclosure",
      text: "Playback is simulated. This page does not request or cache private media.",
    }),
  );
}

function renderReviewQueue() {
  const list = element("div", { className: "list-surface" });
  list.append(...presentationFixture.reviewQueue.map(reviewRow));
  contentPanel.replaceChildren(
    contentHeader("Teacher workspace", "To review", "Submitted evidence from students in this course."),
    list,
  );
}

function renderReviewDetail() {
  const entry = presentationFixture.reviewQueue[0];
  const reflection = append(
    element("section", { className: "grouped-section" }),
    element("h4", { text: "Student reflection" }),
    element("p", { text: entry.notes }),
    metadataList([
      ["Duration", entry.duration],
      ["Scope", "Teacher course membership"],
    ]),
    buttonRow(commandButton("Compose feedback", "feedback-editor")),
  );
  contentPanel.replaceChildren(
    contentHeader("Submission detail", entry.goal, entry.student + " · " + entry.date, statusPill(entry.status)),
    append(
      element("div", { className: "detail-grid" }),
      mediaStage(
        "Authorized source media ready",
        "Audio · 01:05 · private course review",
        commandButton("Play evidence", "play"),
      ),
      reflection,
    ),
    element("p", {
      className: "simulation-disclosure",
      text: "Playback and feedback commands are simulated. No authorized URL is requested and no feedback is persisted.",
    }),
  );
}

function renderFeedbackEditor() {
  const entry = presentationFixture.reviewQueue[0];
  const outcome = element("select", { attributes: { id: "outcome" } });
  outcome.append(
    element("option", { text: "Next goal" }),
    element("option", { text: "Needs revision" }),
    element("option", { text: "Complete" }),
  );
  const feedback = element("textarea", {
    attributes: { id: "feedback" },
    text: "The phrase is much more connected. Next, keep the release light before increasing the tempo.",
  });
  const form = append(
    element("form", { className: "grouped-section", attributes: { id: "feedback-form" } }),
    element("h4", { text: "Structured feedback" }),
    append(
      element("div", { className: "editor-field" }),
      element("label", { attributes: { for: "outcome" }, text: "Outcome" }),
      outcome,
    ),
    append(
      element("div", { className: "editor-field" }),
      element("label", { attributes: { for: "feedback" }, text: "Feedback" }),
      feedback,
    ),
    markerNode({ time: "00:18", text: "Excellent voicing here." }),
    button("text-button", "Add marker at current playback time", { "data-command": "marker" }, true),
    buttonRow(
      element("button", { className: "command-button", attributes: { type: "submit" } }),
      button("secondary-button", "Cancel", { "data-view": "review-detail" }),
    ),
  );
  form.querySelector('button[type="submit"]').append(document.createTextNode("Queue feedback"), simulationTag());
  contentPanel.replaceChildren(
    contentHeader("Teacher workspace", "Feedback", entry.student + " · " + entry.goal),
    append(
      element("div", { className: "detail-grid" }),
      mediaStage("Practice audio · 01:05", "Playback position 00:18", commandButton("Play evidence", "play")),
      form,
    ),
    element("p", {
      className: "simulation-disclosure",
      text: "Editing remains inside this browser tab. Queue feedback does not send, store, or synchronize anything.",
    }),
  );
}

function renderConfirmation() {
  contentPanel.replaceChildren(
    append(
      element("div", { className: "confirmation" }),
      statusPill("Queued"),
      element("h3", { text: "Feedback queued in the simulation." }),
      element("p", {
        text: "The real app would keep the command durable until sync succeeds. This static page only changed its local display and sent no command.",
      }),
      buttonRow(
        button("secondary-button", "Return to review queue", { "data-view": "review" }),
        button("text-button", "View student feedback", { "data-role-jump": "student" }),
      ),
    ),
  );
}

function renderToolView(view) {
  let title;
  let description;
  if (view === "calendar") {
    title = "Calendar";
    description = "Course dates would appear here. Calendar refresh and save actions are omitted from the static walkthrough.";
  } else if (view === "sync") {
    title = "Sync status";
    description = "This view names pending and failed work without processing, retrying, refreshing, or deleting queue items.";
  } else if (view === "settings") {
    title = "Settings";
    description = "Account, sign-out, and local-data deletion controls are omitted because this page has no account or local profile.";
  } else {
    title = "Reviewed";
    description = "The focused walkthrough keeps one submitted item in the teacher queue and one reviewed item in the student view.";
  }
  contentPanel.replaceChildren(
    contentHeader("Structured demo", title, description),
    append(
      element("section", { className: "grouped-section" }),
      element("h4", { text: "Simulation boundary" }),
      element("p", { text: "No command-capable control is provided in this supporting view. Return to the core role flow using the navigation." }),
    ),
  );
}

function renderContent() {
  const renderers = new Map([
    ["entries", renderStudentEntries],
    ["entry-detail", renderStudentDetail],
    ["reviewed", renderReviewedFeedback],
    ["review", renderReviewQueue],
    ["review-detail", renderReviewDetail],
    ["feedback-editor", renderFeedbackEditor],
    ["confirmation", renderConfirmation],
  ]);
  const renderer = renderers.get(state.view);
  (renderer || (() => renderToolView(state.view)))();
}

function render() {
  renderSidebar();
  renderContent();
}

document.querySelectorAll("[data-role]").forEach((roleButton) => {
  roleButton.addEventListener("click", () => {
    state.role = roleButton.dataset.role;
    state.view = state.role === "student" ? "entries" : "review";
    document.querySelectorAll("[data-role]").forEach((candidate) => {
      const active = candidate === roleButton;
      candidate.classList.toggle("is-active", active);
      candidate.setAttribute("aria-pressed", String(active));
    });
    render();
  });
});

document.addEventListener("click", (event) => {
  const viewButton = event.target.closest("[data-view]");
  const entryButton = event.target.closest("[data-entry]");
  const reviewButton = event.target.closest("[data-review]");
  const commandButton = event.target.closest("[data-command]");
  const roleJump = event.target.closest("[data-role-jump]");

  if (viewButton) {
    state.view = viewButton.dataset.view;
    render();
  } else if (entryButton) {
    state.selectedEntry = entryButton.dataset.entry;
    state.view = "entry-detail";
    render();
  } else if (reviewButton) {
    state.view = "review-detail";
    render();
  } else if (commandButton) {
    if (commandButton.dataset.command === "submit") {
      state.queued = true;
      render();
    } else {
      commandButton.setAttribute("aria-live", "polite");
      commandButton.firstChild.textContent = commandButton.dataset.command === "marker" ? "Marker staged " : "Visual state changed ";
    }
  } else if (roleJump) {
    state.role = "student";
    state.view = "reviewed";
    document.querySelectorAll("[data-role]").forEach((candidate) => {
      const active = candidate.dataset.role === "student";
      candidate.classList.toggle("is-active", active);
      candidate.setAttribute("aria-pressed", String(active));
    });
    render();
  }
});

document.addEventListener("submit", (event) => {
  if (event.target.matches("#feedback-form")) {
    event.preventDefault();
    state.view = "confirmation";
    render();
  }
});

render();
