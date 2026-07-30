"use strict";

const presentationFixture = Object.freeze({
  course: "Mock University · Piano Studio I",
  student: "Lea Sommer",
  teacher: "Prof. Anna Berg",
  entries: [
    {
      key: "draft",
      goal: "Draft: octaves warmup pattern",
      detailGoal: "Octaves warmup pattern",
      date: "23 February 2026",
      duration: "6 min",
      notes: "Still experimenting with fingering.",
      status: "Draft",
    },
    {
      key: "submitted",
      goal: "Improve legato transitions in Chopin Nocturne",
      detailGoal: "Improve legato transitions in Chopin Nocturne",
      date: "20 February 2026",
      duration: "15 min",
      notes: "Left hand balance and softer pedal.",
      status: "Submitted",
    },
    {
      key: "reviewed",
      goal: "Phrase shaping in Debussy prelude",
      detailGoal: "Phrase shaping in Debussy prelude",
      date: "18 February 2026",
      duration: "14 min",
      notes: "Try broader dynamic contrast.",
      status: "Reviewed",
    },
  ],
  reviewQueue: [
    {
      key: "lea",
      student: "Lea Sommer",
      goal: "Improve legato transitions in Chopin Nocturne",
      date: "20 February 2026",
      duration: "15 min",
      notes: "Left hand balance and softer pedal.",
      status: "Submitted",
    },
    {
      key: "noah",
      student: "Noah Keller",
      goal: "Stabilize tempo in Bach invention, hands together",
      date: "21 February 2026",
      duration: "12 min",
      notes: "Focus on metronome consistency.",
      status: "Submitted",
    },
  ],
  feedback: {
    outcome: "Next goal",
    comments: "Great color palette. Next step: slower transitions before full tempo.",
    markers: [
      { time: "00:18", text: "Excellent voicing here." },
      { time: "00:41", text: "Keep wrist relaxed in this passage." },
    ],
  },
});

const icons = {
  courses: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 5.5A2.5 2.5 0 0 1 6.5 3H20v16H6.5A2.5 2.5 0 0 0 4 21.5zM4 5.5v16M8 7h8M8 11h8"></path></svg>',
  entries: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 3h9l3 3v15H6zM14 3v4h4M9 11h6M9 15h6"></path></svg>',
  review: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 5h16v14H4zM8 9h8M8 13h5"></path></svg>',
  calendar: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 6h16v14H4zM8 3v6M16 3v6M4 10h16"></path></svg>',
  sync: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M20 7h-5V2M4 17h5v5M19 12a7 7 0 0 0-12-5L4 10M5 12a7 7 0 0 0 12 5l3-3"></path></svg>',
  settings: '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="3"></circle><path d="M19 12a7 7 0 0 0-.1-1l2-1.5-2-3.4-2.4 1A8 8 0 0 0 15 6.2L14.7 3h-4L10 6.2a8 8 0 0 0-1.5.9l-2.4-1-2 3.4L6.1 11a7 7 0 0 0 0 2l-2 1.5 2 3.4 2.4-1a8 8 0 0 0 1.5.9l.7 3.2h4l.3-3.2a8 8 0 0 0 1.5-.9l2.4 1 2-3.4-2-1.5a7 7 0 0 0 .1-1z"></path></svg>',
};

const state = {
  role: "student",
  view: "entries",
  selectedEntry: "draft",
  queued: false,
};

const contentPanel = document.querySelector("#content-panel");
const sidebarNav = document.querySelector("#sidebar-nav");
const personaName = document.querySelector("#persona-name");
const personaRole = document.querySelector("#persona-role");
const syncTitle = document.querySelector("#sync-title");
const syncDetail = document.querySelector("#sync-detail");

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function simulationTag() {
  return '<span class="simulation-tag">Simulated</span>';
}

function statusPill(status) {
  return `<span class="status-pill status-${status.toLowerCase()}">${escapeHtml(status)}</span>`;
}

function waveform() {
  return '<div class="waveform" aria-hidden="true"><span></span><span></span><span></span><span></span><span></span><span></span><span></span><span></span><span></span></div>';
}

function renderSidebar() {
  const isStudent = state.role === "student";
  personaName.textContent = isStudent ? presentationFixture.student : presentationFixture.teacher;
  personaRole.textContent = `${isStudent ? "Student" : "Teacher"} · simulated session`;
  syncTitle.textContent = isStudent ? (state.queued ? "3 items waiting" : "2 items waiting") : "Feedback queue ready";
  syncDetail.textContent = isStudent ? "One upload needs attention" : "No command sent";

  const items = isStudent
    ? [
        ["entries", "Practice entries", icons.entries],
        ["reviewed", "Reviewed feedback", icons.review],
      ]
    : [
        ["review", "To review", icons.review],
        ["reviewed-list", "Reviewed", icons.entries],
      ];

  sidebarNav.innerHTML = `
    <span class="nav-section-label">${escapeHtml(presentationFixture.course)}</span>
    ${items
      .map(
        ([view, label, icon]) => `
          <button class="nav-button ${state.view === view ? "is-active" : ""}" type="button" data-view="${view}">
            ${icon}<span>${escapeHtml(label)}</span>
          </button>`,
      )
      .join("")}
    <span class="nav-section-label">Tools</span>
    <button class="nav-button" type="button" data-view="calendar">${icons.calendar}<span>Calendar</span></button>
    <button class="nav-button" type="button" data-view="sync">${icons.sync}<span>Sync status</span></button>
    <button class="nav-button" type="button" data-view="settings">${icons.settings}<span>Settings</span></button>
  `;
}

function contentHeader(label, title, description, trailing = "") {
  return `
    <header class="content-header">
      <div><span class="section-label">${escapeHtml(label)}</span><h3>${escapeHtml(title)}</h3><p>${escapeHtml(description)}</p></div>
      ${trailing}
    </header>`;
}

function renderStudentEntries() {
  contentPanel.innerHTML = `
    ${contentHeader("Student workspace", "Practice entries", "Evidence stays explicit from local draft through reviewed feedback.")}
    <div class="list-surface">
      ${presentationFixture.entries
        .map(
          (entry) => `
            <button class="entry-row" type="button" data-entry="${entry.key}">
              <span><strong>${escapeHtml(entry.goal)}</strong><small>${escapeHtml(entry.date)} · ${escapeHtml(entry.duration)}</small></span>
              <span class="row-meta">${statusPill(entry.key === "draft" && state.queued ? "Queued" : entry.status)}<span class="row-arrow" aria-hidden="true">›</span></span>
            </button>`,
        )
        .join("")}
    </div>`;
}

function renderStudentDetail() {
  const entry = presentationFixture.entries.find((candidate) => candidate.key === state.selectedEntry);
  const status = entry.key === "draft" && state.queued ? "Queued" : entry.status;
  const feedbackSection = entry.key === "reviewed"
    ? `<section class="grouped-section"><h4>Teacher feedback</h4><p>${escapeHtml(presentationFixture.feedback.comments)}</p>${presentationFixture.feedback.markers.map((marker) => `<div class="feedback-marker"><time>${marker.time}</time><p>${escapeHtml(marker.text)}</p></div>`).join("")}</section>`
    : '<section class="grouped-section"><h4>Teacher feedback</h4><p class="muted">No feedback yet. Submit the entry so your teacher can review it.</p></section>';

  contentPanel.innerHTML = `
    ${contentHeader("Practice entry", entry.detailGoal, `${entry.date} · ${entry.duration}`, statusPill(status))}
    <div class="detail-grid">
      <div>
        <section class="media-stage">
          ${waveform()}
          <strong>${entry.key === "draft" ? "Practice audio not recorded" : "Practice audio · 01:05"}</strong>
          <span class="muted">${entry.key === "draft" ? "Microphone access is never requested by this page." : "Playback is visual only in this static demo."}</span>
          <div class="button-row">
            <button class="command-button" type="button" data-command="play">${entry.key === "draft" ? "Record audio" : "Play evidence"}${simulationTag()}</button>
          </div>
        </section>
        <div class="button-row">
          ${entry.key === "draft" ? `<button class="command-button" type="button" data-command="submit">Submit for review${simulationTag()}</button>` : ""}
          <button class="secondary-button" type="button" data-view="entries">Back to entries</button>
        </div>
        <p class="simulation-disclosure">Command-capable controls change this page's local display only. No recording, upload, submission, playback request, or sync command is sent.</p>
      </div>
      <div>
        <section class="grouped-section">
          <h4>Entry details</h4>
          <dl class="metadata-list">
            <div><dt>Status</dt><dd>${escapeHtml(status)}</dd></div>
            <div><dt>Reflection</dt><dd>${escapeHtml(entry.notes)}</dd></div>
            <div><dt>Privacy</dt><dd>Private course review</dd></div>
          </dl>
        </section>
        ${feedbackSection}
      </div>
    </div>`;
}

function renderReviewedFeedback() {
  const entry = presentationFixture.entries.find((candidate) => candidate.key === "reviewed");
  contentPanel.innerHTML = `
    ${contentHeader("Student workspace", "Reviewed feedback", "Feedback is attached to the submitted practice evidence.", statusPill("Reviewed"))}
    <div class="detail-grid">
      <section class="media-stage">${waveform()}<strong>${escapeHtml(entry.detailGoal)}</strong><span class="muted">Practice audio · 01:12</span><div class="button-row"><button class="command-button" type="button" data-command="play">Play evidence${simulationTag()}</button></div></section>
      <section class="grouped-section">
        <h4>${escapeHtml(presentationFixture.feedback.outcome)}</h4>
        <p>${escapeHtml(presentationFixture.feedback.comments)}</p>
        ${presentationFixture.feedback.markers.map((marker) => `<div class="feedback-marker"><time>${marker.time}</time><p>${escapeHtml(marker.text)}</p></div>`).join("")}
      </section>
    </div>
    <p class="simulation-disclosure">Playback is simulated. This page does not request or cache private media.</p>`;
}

function renderReviewQueue() {
  contentPanel.innerHTML = `
    ${contentHeader("Teacher workspace", "To review", "Submitted evidence from students in this course.")}
    <div class="list-surface">
      ${presentationFixture.reviewQueue
        .map(
          (entry) => `
            <button class="entry-row" type="button" data-review="${entry.key}">
              <span><strong>${escapeHtml(entry.student)}</strong><small>${escapeHtml(entry.goal)} · ${escapeHtml(entry.date)}</small></span>
              <span class="row-meta">${statusPill(entry.status)}<span class="row-arrow" aria-hidden="true">›</span></span>
            </button>`,
        )
        .join("")}
    </div>`;
}

function renderReviewDetail() {
  const entry = presentationFixture.reviewQueue[0];
  contentPanel.innerHTML = `
    ${contentHeader("Submission detail", entry.goal, `${entry.student} · ${entry.date}`, statusPill(entry.status))}
    <div class="detail-grid">
      <section class="media-stage">
        ${waveform()}
        <strong>Authorized source media ready</strong>
        <span class="muted">Audio · 01:05 · private course review</span>
        <div class="button-row"><button class="command-button" type="button" data-command="play">Play evidence${simulationTag()}</button></div>
      </section>
      <section class="grouped-section">
        <h4>Student reflection</h4>
        <p>${escapeHtml(entry.notes)}</p>
        <dl class="metadata-list"><div><dt>Duration</dt><dd>${escapeHtml(entry.duration)}</dd></div><div><dt>Scope</dt><dd>Teacher course membership</dd></div></dl>
        <div class="button-row"><button class="command-button" type="button" data-view="feedback-editor">Compose feedback${simulationTag()}</button></div>
      </section>
    </div>
    <p class="simulation-disclosure">Playback and feedback commands are simulated. No authorized URL is requested and no feedback is persisted.</p>`;
}

function renderFeedbackEditor() {
  const entry = presentationFixture.reviewQueue[0];
  contentPanel.innerHTML = `
    ${contentHeader("Teacher workspace", "Feedback", `${entry.student} · ${entry.goal}`)}
    <div class="detail-grid">
      <section class="media-stage">${waveform()}<strong>Practice audio · 01:05</strong><span class="muted">Playback position 00:18</span><div class="button-row"><button class="command-button" type="button" data-command="play">Play evidence${simulationTag()}</button></div></section>
      <form class="grouped-section" id="feedback-form">
        <h4>Structured feedback</h4>
        <div class="editor-field"><label for="outcome">Outcome</label><select id="outcome"><option>Next goal</option><option>Needs revision</option><option>Complete</option></select></div>
        <div class="editor-field"><label for="feedback">Feedback</label><textarea id="feedback">The phrase is much more connected. Next, keep the release light before increasing the tempo.</textarea></div>
        <div class="feedback-marker"><time>00:18</time><p>Excellent voicing here.</p></div>
        <button class="text-button" type="button" data-command="marker">Add marker at current playback time${simulationTag()}</button>
        <div class="button-row"><button class="command-button" type="submit">Queue feedback${simulationTag()}</button><button class="secondary-button" type="button" data-view="review-detail">Cancel</button></div>
      </form>
    </div>
    <p class="simulation-disclosure">Editing remains inside this browser tab. Queue feedback does not send, store, or synchronize anything.</p>`;
}

function renderConfirmation() {
  contentPanel.innerHTML = `
    <div class="confirmation">
      ${statusPill("Queued")}
      <h3>Feedback queued in the simulation.</h3>
      <p>The real app would keep the command durable until sync succeeds. This static page only changed its local display and sent no command.</p>
      <div class="button-row"><button class="secondary-button" type="button" data-view="review">Return to review queue</button><button class="text-button" type="button" data-role-jump="student">View student feedback</button></div>
    </div>`;
}

function renderToolView(view) {
  const copy = {
    calendar: ["Calendar", "Course dates would appear here. Calendar refresh and save actions are omitted from the static walkthrough."],
    sync: ["Sync status", "This view names pending and failed work without processing, retrying, refreshing, or deleting queue items."],
    settings: ["Settings", "Account, sign-out, and local-data deletion controls are omitted because this page has no account or local profile."],
    "reviewed-list": ["Reviewed", "The focused walkthrough keeps one submitted item in the teacher queue and one reviewed item in the student view."],
  };
  const [title, description] = copy[view];
  contentPanel.innerHTML = `
    ${contentHeader("Structured demo", title, description)}
    <section class="grouped-section"><h4>Simulation boundary</h4><p>No command-capable control is provided in this supporting view. Return to the core role flow using the navigation.</p></section>`;
}

function renderContent() {
  const renderers = {
    entries: renderStudentEntries,
    "entry-detail": renderStudentDetail,
    reviewed: renderReviewedFeedback,
    review: renderReviewQueue,
    "review-detail": renderReviewDetail,
    "feedback-editor": renderFeedbackEditor,
    confirmation: renderConfirmation,
  };
  (renderers[state.view] || (() => renderToolView(state.view)))();
}

function render() {
  renderSidebar();
  renderContent();
}

document.querySelectorAll("[data-role]").forEach((button) => {
  button.addEventListener("click", () => {
    state.role = button.dataset.role;
    state.view = state.role === "student" ? "entries" : "review";
    document.querySelectorAll("[data-role]").forEach((candidate) => {
      const active = candidate === button;
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
