"use strict";

const presentationFixture = Object.freeze({
  university: "Mock University",
  course: "Piano Studio I",
  student: "Lea Sommer",
  teacher: "Prof. Anna Berg",
  entries: [
    {
      id: "lea-draft",
      student: "Lea Sommer",
      title: "Octaves warmup pattern",
      date: "23 Feb",
      time: "12:30",
      duration: 33,
      practiceDuration: "6 min",
      medium: "Audio",
      status: "failed",
      note: "Still experimenting with fingering.",
      tags: ["warmup", "octaves"],
      markers: [],
    },
    {
      id: "lea-submitted",
      student: "Lea Sommer",
      title: "Legato transitions — Chopin Nocturne op. 9",
      date: "20 Feb",
      time: "09:15",
      duration: 65,
      practiceDuration: "15 min",
      medium: "Audio",
      status: "submitted",
      note: "Left hand balance and softer pedal. Transitions still rush before the cadence.",
      tags: ["legato", "chopin"],
      markers: [
        { id: "lea-submitted-18", seconds: 18, text: "Left-hand balance" },
        { id: "lea-submitted-42", seconds: 42, text: "Pedal release" },
        { id: "lea-submitted-61", seconds: 61, text: "Final phrase — tempo" },
      ],
    },
    {
      id: "noah-submitted",
      student: "Noah Keller",
      title: "Stabilize tempo in Bach invention, hands together",
      date: "21 Feb",
      time: "11:00",
      duration: 58,
      practiceDuration: "12 min",
      medium: "Audio",
      status: "queued",
      note: "Focus on metronome consistency.",
      tags: ["bach", "tempo"],
      markers: [],
    },
    {
      id: "lea-reviewed",
      student: "Lea Sommer",
      title: "Phrase shaping in Debussy prelude",
      date: "18 Feb",
      time: "07:30",
      duration: 72,
      practiceDuration: "14 min",
      medium: "Audio",
      status: "reviewed",
      note: "Try broader dynamic contrast.",
      tags: ["debussy", "phrasing"],
      verdict: "Next goal",
      feedback: "Great color palette. Next step: slower transitions before full tempo.",
      markers: [
        { id: "lea-reviewed-18", seconds: 18, text: "Excellent voicing here." },
        { id: "lea-reviewed-41", seconds: 41, text: "Keep wrist relaxed in this passage." },
      ],
    },
  ],
});

const waveformHeights = [
  28, 48, 66, 42, 24, 52, 78, 60, 35, 20, 43, 64, 31, 22, 37, 72, 53, 28, 45,
  62, 39, 25, 46, 58, 33, 22, 51, 81, 38, 25, 34, 69, 43, 22, 57, 31, 18, 42, 65,
  36, 54, 27,
];

function freshState() {
  return {
    role: "student",
    entries: presentationFixture.entries.map((entry) => ({
      ...entry,
      tags: [...entry.tags],
      markers: entry.markers.map((marker) => ({ ...marker })),
    })),
    selectedStudentEntry: "lea-draft",
    selectedTeacherEntry: "lea-submitted",
    queueFilter: "review",
    selectedMarker: null,
    selectedVerdict: "Next goal",
    feedbackText: "Great color palette. Next step: slower transitions before full tempo.",
    feedbackSent: false,
    playbackSecond: 25,
    isPlaying: false,
    recording: false,
    recordingSeconds: 0,
    recordingMarkers: 0,
  };
}

let state = freshState();
let recordingTimer;

const contentPanel = document.querySelector("#content-panel");
const sidebarContent = document.querySelector("#sidebar-content");
const personaName = document.querySelector("#persona-name");
const personaInitials = document.querySelector("#persona-initials");
const syncSummary = document.querySelector("#sync-summary");
const courseCount = document.querySelector("#course-count");
const demoStatus = document.querySelector("#demo-status");
const captureDialog = document.querySelector("#capture-dialog");
const consentCheckbox = document.querySelector("#consent-checkbox");
const captureToggle = document.querySelector("#capture-toggle");
const captureMarker = document.querySelector("#capture-marker");
const captureTimer = document.querySelector("#capture-timer");
const captureState = document.querySelector("#capture-state");
const liveWaveform = document.querySelector("#live-waveform");

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

function simulationTag() {
  return element("span", { className: "simulation-tag", text: "Simulated" });
}

function commandButton(text, command, className = "command-button") {
  return button(className, text, { "data-command": command }, true);
}

function announce(message) {
  demoStatus.textContent = "";
  globalThis.requestAnimationFrame(() => {
    demoStatus.textContent = message;
  });
}

function formatTime(seconds) {
  const wholeSeconds = Math.max(0, Math.floor(seconds));
  const minutes = Math.floor(wholeSeconds / 60);
  return `${minutes}:${String(wholeSeconds % 60).padStart(2, "0")}`;
}

function statusLabel(status) {
  return new Map([
    ["local", "Local only"],
    ["queued", "Queued"],
    ["submitted", "Submitted"],
    ["reviewed", "Reviewed"],
    ["failed", "Sync failed"],
    ["uploading", "Uploading"],
  ]).get(status) ?? status;
}

function statusPill(status) {
  return element("span", {
    className: `status-pill status-${status}`,
    text: statusLabel(status),
  });
}

function selectedEntry(id) {
  return state.entries.find((entry) => entry.id === id) ?? state.entries[0];
}

function queueEntries() {
  if (state.queueFilter === "reviewed") {
    return state.entries.filter((entry) => entry.status === "reviewed");
  }
  return state.entries.filter((entry) => entry.status === "submitted" || entry.status === "queued");
}

function rowButton(entry, selected, kind) {
  const node = button(`${kind}-button${selected ? " is-selected" : ""}`, "", {
    "data-entry-id": entry.id,
    "aria-pressed": String(selected),
  });
  const top = append(
    element("span", { className: "row-top" }),
    element("strong", { text: kind === "queue" ? entry.student : entry.date }),
    element("span", { className: "row-time", text: entry.time }),
  );
  const goal = element("span", { className: "row-goal", text: entry.title });
  const meta = append(
    element("span", { className: "row-meta" }),
    element("span", { text: `${entry.medium} · ${formatTime(entry.duration)}` }),
    statusPill(entry.status),
  );
  node.append(top, goal, meta);
  return node;
}

function filterButton(value, label, count) {
  const active = state.queueFilter === value;
  const node = button(`filter-button${active ? " is-active" : ""}`, "", {
    "data-filter": value,
    "aria-pressed": String(active),
  });
  node.append(document.createTextNode(label));
  node.append(element("span", { className: "filter-count", text: String(count) }));
  return node;
}

function renderSidebar() {
  sidebarContent.replaceChildren();
  if (state.role === "teacher") {
    const reviewCount = state.entries.filter((entry) =>
      ["submitted", "queued"].includes(entry.status),
    ).length;
    const reviewedCount = state.entries.filter((entry) => entry.status === "reviewed").length;
    const filters = append(
      element("div", { className: "filter-switch", attributes: { role: "group", "aria-label": "Queue filter" } }),
      filterButton("review", "To review", reviewCount),
      filterButton("reviewed", "Reviewed", reviewedCount),
    );
    sidebarContent.append(append(element("div", { className: "sidebar-controls" }), filters));

    const list = element("ul", { className: "queue-list" });
    for (const entry of queueEntries()) {
      const item = element("li");
      item.append(rowButton(entry, entry.id === state.selectedTeacherEntry, "queue"));
      list.append(item);
    }
    if (list.childElementCount === 0) {
      list.append(
        append(
          element("li", { className: "empty-state" }),
          element("h2", { text: "Queue is clear" }),
          element("p", { text: "New submissions will appear here when a student shares evidence." }),
        ),
      );
    }
    sidebarContent.append(list);
  } else {
    sidebarContent.append(element("div", { className: "list-divider", text: "Practice journal" }));
    const list = element("ul", { className: "entry-list" });
    for (const entry of state.entries.filter((item) => item.student === presentationFixture.student)) {
      const item = element("li");
      item.append(rowButton(entry, entry.id === state.selectedStudentEntry, "entry"));
      list.append(item);
    }
    sidebarContent.append(list);
  }

  sidebarContent.querySelectorAll("[data-filter]").forEach((node) => {
    node.addEventListener("click", () => {
      state.queueFilter = node.dataset.filter;
      const first = queueEntries()[0];
      if (first) {
        state.selectedTeacherEntry = first.id;
      }
      state.feedbackSent = false;
      render();
    });
  });

  sidebarContent.querySelectorAll("[data-entry-id]").forEach((node) => {
    node.addEventListener("click", () => {
      if (state.role === "teacher") {
        state.selectedTeacherEntry = node.dataset.entryId;
        state.feedbackSent = false;
      } else {
        state.selectedStudentEntry = node.dataset.entryId;
      }
      state.selectedMarker = null;
      render();
    });
  });
}

function detailHeader(entry, actions) {
  const kicker = append(
    element("div", { className: "detail-kicker" }),
    element("span", { text: `${entry.student} · ${entry.date}, ${entry.time}` }),
    statusPill(entry.status),
  );
  const heading = append(
    element("div"),
    kicker,
    element("h2", { text: entry.title }),
  );
  return append(element("header", { className: "detail-header" }), heading, actions);
}

function waveform(entry, markers = entry.markers) {
  const container = element("div", {
    className: "waveform",
    attributes: { role: "img", "aria-label": `Waveform for ${entry.title}` },
  });
  waveformHeights.forEach((height, index) => {
    const barSecond = (index / (waveformHeights.length - 1)) * entry.duration;
    const className = barSecond <= state.playbackSecond ? "wave-bar is-played" : "wave-bar";
    const bar = element("span", { className });
    bar.style.height = `${height}%`;
    container.append(bar);
  });
  markers.forEach((marker, index) => {
    const pin = button(`marker-pin${state.selectedMarker === marker.id ? " is-selected" : ""}`, String(index + 1), {
      "data-marker-id": marker.id,
      "aria-label": `${formatTime(marker.seconds)} ${marker.text}`,
    });
    pin.style.left = `${Math.min(98, Math.max(2, (marker.seconds / entry.duration) * 100))}%`;
    container.append(pin);
  });
  return container;
}

function markerChips(markers) {
  const chips = element("div", { className: "marker-chips" });
  markers.forEach((marker) => {
    const chip = button(`marker-chip${state.selectedMarker === marker.id ? " is-selected" : ""}`, "", {
      "data-marker-id": marker.id,
    });
    chip.append(
      element("strong", { text: formatTime(marker.seconds) }),
      document.createTextNode(marker.text),
    );
    chips.append(chip);
  });
  return chips;
}

function mediaStage(entry, markers = entry.markers) {
  const stage = element("section", { className: "media-stage", attributes: { "aria-label": "Practice audio" } });
  const meta = append(
    element("div", { className: "stage-meta" }),
    element("strong", { text: `${entry.student.toLowerCase().replace(" ", "-")} · practice audio` }),
    element("span", { text: "44.1 kHz · private to course" }),
  );
  const play = button("play-button", state.isPlaying ? "Ⅱ" : "▶", {
    "data-playback": "toggle",
    "aria-label": state.isPlaying ? "Pause simulated audio" : "Play simulated audio",
  });
  const controls = append(
    element("div", { className: "stage-controls" }),
    play,
    element("span", {
      className: "timecode",
      text: `${formatTime(state.playbackSecond)} / ${formatTime(entry.duration)}`,
    }),
  );
  stage.append(meta, waveform(entry, markers), controls, markerChips(markers));
  return stage;
}

function humanNote(entry) {
  return append(
    element("section", { className: "human-note" }),
    element("span", { className: "section-label", text: "Student's note" }),
    element("blockquote", { text: entry.note }),
    element("cite", { text: `${entry.student} · ${entry.date} · practice ${entry.practiceDuration}` }),
  );
}

function bindMediaInteractions(root, entry) {
  root.querySelector("[data-playback]")?.addEventListener("click", () => {
    state.isPlaying = !state.isPlaying;
    state.playbackSecond = state.isPlaying
      ? Math.min(entry.duration, state.playbackSecond + 7)
      : state.playbackSecond;
    announce(state.isPlaying ? "Simulated playback started." : "Simulated playback paused.");
    renderContent();
  });
  root.querySelectorAll("[data-marker-id]").forEach((node) => {
    node.addEventListener("click", () => {
      const marker = entry.markers.find((item) => item.id === node.dataset.markerId);
      if (!marker) {
        return;
      }
      state.selectedMarker = marker.id;
      state.playbackSecond = marker.seconds;
      announce(`Marker selected at ${formatTime(marker.seconds)}: ${marker.text}`);
      renderContent();
    });
  });
}

function renderStudent() {
  const entry = selectedEntry(state.selectedStudentEntry);
  const capture = commandButton("Capture practice", "capture");
  const header = append(
    element("header", { className: "journal-header" }),
    append(
      element("div"),
      element("span", { className: "caps-label", text: "Offline-ready journal" }),
      element("h2", { className: "journal-title", text: "Practice journal" }),
    ),
    capture,
  );

  const detail = element("section", { className: "journal-detail" });
  const summary = append(
    element("div", { className: "entry-summary" }),
    append(
      element("div", { className: "detail-kicker" }),
      element("span", { text: `${entry.date} · ${entry.practiceDuration}` }),
      statusPill(entry.status),
    ),
    element("h2", { text: entry.title }),
    append(
      element("div", { className: "entry-facts" }),
      element("span", { text: `${entry.medium} · ${formatTime(entry.duration)}` }),
      element("span", { text: entry.tags.join(" · ") }),
    ),
  );
  detail.append(summary);
  if (entry.duration > 0) {
    const label = element("span", { className: "section-label", text: "Practice evidence" });
    label.style.marginTop = "24px";
    detail.append(label, mediaStage(entry), humanNote(entry));
  }

  if (entry.status === "failed") {
    const retry = commandButton("Retry sync", "retry", "retry-button");
    const failure = append(
      element("section", { className: "sync-failure" }),
      element("strong", { text: "Sync failed" }),
      element("p", { text: "The recording remains safely on this device. Retry whenever a connection returns." }),
      retry,
    );
    retry.addEventListener("click", () => {
      entry.status = "queued";
      announce("Practice evidence queued. No network request was made.");
      render();
    });
    detail.append(failure);
  }

  const timeline = element("aside", { className: "feedback-timeline", attributes: { "aria-label": "Teacher feedback" } });
  timeline.append(element("span", { className: "section-label", text: "Teacher feedback" }));
  if (entry.feedback) {
    timeline.append(
      append(
        element("div", { className: "detail-kicker" }),
        element("span", { text: `${presentationFixture.teacher} · ${entry.verdict}` }),
        statusPill("reviewed"),
      ),
      element("p", { text: entry.feedback }),
    );
    const list = element("ol", { className: "timeline-list" });
    entry.markers.forEach((marker) => {
      list.append(
        append(
          element("li", { className: "timeline-item" }),
          element("span", { className: "timeline-time", text: formatTime(marker.seconds) }),
          element("p", { text: marker.text }),
        ),
      );
    });
    timeline.append(list);
  } else {
    timeline.append(
      append(
        element("div", { className: "empty-state" }),
        element("h2", { text: entry.status === "submitted" ? "Awaiting review" : "No feedback yet" }),
        element("p", {
          text:
            entry.status === "submitted"
              ? "Prof. Anna Berg will see this entry in the private review queue."
              : "Submit this entry when it is ready for your teacher.",
        }),
      ),
    );
  }

  const body = append(element("div", { className: "journal-body" }), detail, timeline);
  contentPanel.append(append(element("div", { className: "journal-layout" }), header, body));
  capture.addEventListener("click", openCapture);
  bindMediaInteractions(detail, entry);
}

function verdictButton(value) {
  return button(`verdict-button${state.selectedVerdict === value ? " is-selected" : ""}`, value, {
    "data-verdict": value,
    "aria-pressed": String(state.selectedVerdict === value),
  });
}

function renderFeedbackSuccess(entry) {
  const back = button("secondary-button", "Return to queue");
  back.addEventListener("click", () => {
    entry.status = "reviewed";
    entry.feedback = state.feedbackText;
    entry.verdict = state.selectedVerdict;
    state.feedbackSent = false;
    state.queueFilter = "review";
    const next = queueEntries().find((item) => item.id !== entry.id);
    if (next) {
      state.selectedTeacherEntry = next.id;
    }
    render();
  });
  contentPanel.append(
    append(
      element("section", { className: "success-state" }),
      statusPill("queued"),
      element("h2", { text: "Feedback queued" }),
      element("p", {
        text: "The simulated feedback is now waiting to sync. Lea can keep practicing while either side is offline.",
      }),
      back,
    ),
  );
}

function renderTeacher() {
  const entry = selectedEntry(state.selectedTeacherEntry);
  if (state.feedbackSent) {
    renderFeedbackSuccess(entry);
    return;
  }

  const openStudent = commandButton("Open student", "open-student", "secondary-button");
  const jumpComposer = button("primary-button", "Write feedback", { "data-command": "focus-feedback" });
  const actions = append(element("div", { className: "button-row" }), openStudent, jumpComposer);
  contentPanel.append(detailHeader(entry, actions));

  const evidence = element("section", { className: "evidence-column" });
  evidence.append(
    element("span", { className: "section-label", text: "Evidence · practice audio" }),
    mediaStage(entry),
    humanNote(entry),
  );

  const composer = element("aside", { className: "composer-column", attributes: { "aria-label": "Feedback composer" } });
  composer.append(element("span", { className: "section-label", text: "Verdict" }));
  const verdicts = append(
    element("div", { className: "verdict-group", attributes: { role: "group", "aria-label": "Feedback verdict" } }),
    verdictButton("On track"),
    verdictButton("Needs revision"),
    verdictButton("Next goal"),
  );
  const form = element("form", { className: "feedback-form" });
  const feedbackId = "feedback-text";
  const textarea = element("textarea", {
    attributes: { id: feedbackId, name: "feedback", required: "", maxlength: "500" },
  });
  textarea.value = state.feedbackText;
  const addMarker = commandButton(
    `Add marker at ${formatTime(state.playbackSecond)}`,
    "add-marker",
    "secondary-button",
  );
  const submit = button("command-button", "Send feedback", { type: "submit" });
  submit.append(simulationTag());
  const footer = append(element("div", { className: "composer-footer" }), addMarker, submit);
  form.append(
    element("label", { attributes: { for: feedbackId }, text: "Private feedback for this entry" }),
    textarea,
    footer,
  );
  composer.append(
    verdicts,
    form,
    element("p", {
      className: "privacy-note",
      text: `Visible only to ${entry.student} and ${presentationFixture.course} teachers. Feedback syncs when either side is online.`,
    }),
  );
  contentPanel.append(append(element("div", { className: "teacher-detail-grid" }), evidence, composer));

  jumpComposer.addEventListener("click", () => textarea.focus());
  openStudent.addEventListener("click", () => {
    state.role = "student";
    state.selectedStudentEntry = entry.id;
    render();
    announce(`${entry.student}'s student view opened.`);
  });
  composer.querySelectorAll("[data-verdict]").forEach((node) => {
    node.addEventListener("click", () => {
      state.selectedVerdict = node.dataset.verdict;
      renderContent();
      announce(`${state.selectedVerdict} selected.`);
    });
  });
  textarea.addEventListener("input", () => {
    state.feedbackText = textarea.value;
  });
  addMarker.addEventListener("click", () => {
    const seconds = Math.min(entry.duration - 1, Math.max(1, state.playbackSecond));
    const marker = {
      id: `${entry.id}-demo-${entry.markers.length + 1}`,
      seconds,
      text: "New teacher note",
    };
    entry.markers.push(marker);
    state.selectedMarker = marker.id;
    renderContent();
    announce(`Marker added at ${formatTime(seconds)}. No data was sent.`);
  });
  form.addEventListener("submit", (event) => {
    event.preventDefault();
    state.feedbackText = textarea.value.trim();
    if (!state.feedbackText) {
      textarea.setCustomValidity("Add feedback before sending.");
      textarea.reportValidity();
      return;
    }
    textarea.setCustomValidity("");
    state.feedbackSent = true;
    announce("Feedback queued in this simulated browser session.");
    renderContent();
  });
  bindMediaInteractions(evidence, entry);
}

function renderContent() {
  contentPanel.replaceChildren();
  if (state.role === "teacher") {
    renderTeacher();
  } else {
    renderStudent();
  }
}

function updateChrome() {
  const teacherMode = state.role === "teacher";
  personaName.textContent = teacherMode ? presentationFixture.teacher : presentationFixture.student;
  personaInitials.textContent = teacherMode ? "AB" : "LS";
  const waiting = state.entries.filter((entry) => ["queued", "failed"].includes(entry.status)).length;
  syncSummary.textContent = teacherMode
    ? "Online · feedback queue ready"
    : `Offline · ${waiting} ${waiting === 1 ? "item" : "items"} waiting`;
  courseCount.textContent = teacherMode
    ? `${state.entries.filter((entry) => ["submitted", "queued"].includes(entry.status)).length} to review`
    : `${state.entries.filter((entry) => entry.student === presentationFixture.student).length} entries`;
  document.querySelectorAll("[data-role]").forEach((node) => {
    const active = node.dataset.role === state.role;
    node.classList.toggle("is-active", active);
    node.setAttribute("aria-pressed", String(active));
  });
}

function render() {
  updateChrome();
  renderSidebar();
  renderContent();
}

function resetCapture() {
  globalThis.clearInterval(recordingTimer);
  state.recording = false;
  state.recordingSeconds = 0;
  state.recordingMarkers = 0;
  consentCheckbox.checked = false;
  captureToggle.disabled = true;
  captureMarker.disabled = true;
  captureToggle.textContent = "Start recording";
  captureTimer.textContent = "0:00";
  captureState.textContent = "Ready to record";
}

function openCapture() {
  resetCapture();
  captureDialog.showModal();
  consentCheckbox.focus();
}

function finishCapture() {
  globalThis.clearInterval(recordingTimer);
  state.recording = false;
  const newEntry = {
    id: `local-capture-${state.entries.length + 1}`,
    student: presentationFixture.student,
    title: "New private practice recording",
    date: "Today",
    time: "Now",
    duration: Math.max(1, state.recordingSeconds),
    practiceDuration: "Just now",
    medium: "Audio",
    status: "local",
    note: `${state.recordingMarkers} ${state.recordingMarkers === 1 ? "marker" : "markers"} added during capture.`,
    tags: ["new take"],
    markers: [],
  };
  state.entries.unshift(newEntry);
  state.selectedStudentEntry = newEntry.id;
  captureDialog.close();
  render();
  announce("A local-only practice entry was added. Nothing left this browser.");
}

function populateLiveWaveform() {
  liveWaveform.replaceChildren();
  waveformHeights.slice(0, 32).forEach((height) => {
    const bar = element("span", { className: "wave-bar" });
    bar.style.height = `${height}%`;
    liveWaveform.append(bar);
  });
}

document.querySelectorAll("[data-role]").forEach((node) => {
  node.addEventListener("click", () => {
    state.role = node.dataset.role;
    state.feedbackSent = false;
    state.selectedMarker = null;
    render();
    announce(`${node.textContent.trim()} demo opened.`);
  });
});

document.querySelector("#reset-demo").addEventListener("click", () => {
  state = freshState();
  resetCapture();
  render();
  announce("Demo reset to the original mock data.");
});

document.querySelector("#sync-command").addEventListener("click", () => {
  let changed = 0;
  state.entries.forEach((entry) => {
    if (entry.status === "failed") {
      entry.status = "queued";
      changed += 1;
    } else if (entry.status === "queued") {
      entry.status = "submitted";
      changed += 1;
    }
  });
  render();
  announce(
    changed > 0
      ? `${changed} mock items advanced to their next sync state. No request was sent.`
      : "Everything in the mock queue is already current.",
  );
});

consentCheckbox.addEventListener("change", () => {
  captureToggle.disabled = !consentCheckbox.checked;
  captureState.textContent = consentCheckbox.checked ? "Consent confirmed · ready" : "Ready to record";
});

captureToggle.addEventListener("click", () => {
  if (!state.recording) {
    state.recording = true;
    captureMarker.disabled = false;
    captureToggle.textContent = "Save recording";
    captureState.textContent = "Recording locally · no microphone is active";
    recordingTimer = globalThis.setInterval(() => {
      state.recordingSeconds += 1;
      captureTimer.textContent = formatTime(state.recordingSeconds);
      liveWaveform.querySelectorAll(".wave-bar").forEach((bar, index) => {
        bar.classList.toggle("is-active", index % 5 === state.recordingSeconds % 5);
      });
    }, 1000);
    announce("Simulated local recording started.");
  } else {
    finishCapture();
  }
});

captureMarker.addEventListener("click", () => {
  state.recordingMarkers += 1;
  captureState.textContent = `${state.recordingMarkers} ${state.recordingMarkers === 1 ? "marker" : "markers"} added`;
  announce(`Capture marker ${state.recordingMarkers} added at ${formatTime(state.recordingSeconds)}.`);
});

captureDialog.addEventListener("close", () => {
  globalThis.clearInterval(recordingTimer);
  state.recording = false;
});

populateLiveWaveform();
render();
