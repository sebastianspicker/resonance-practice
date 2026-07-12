# Scientific Audit: Teaching-Lesson Video

This audit records the evidence basis for Resonance's teaching-lesson video workflow. It is intentionally scoped to video pedagogy and music teacher education, not to a full legal review.

## Evidence Baseline

| Evidence | Product implication | Current repo alignment |
|---|---|---|
| Kramer, Spicker & Kaspar (2023), *Manual zur Erstellung von Unterrichtsvideographien*: define the purpose first, plan consent, room, camera focus, audio, and later use before recording. | Filming must start from a capture purpose, not from "record everything". Consent and intended use must be explicit before upload. | Teaching lessons require private course-review consent before submission. Capture profiles and manual markers encode the purpose/focus without automatic analysis. |
| Classroom videography guidance: camera positions and pans/zooms should follow the lesson or research aim; for authentic whole-lesson representation, static setups are preferred. | Camera overlays should be composition aids only. They must not imply quality scoring or automated interpretation. | The camera view provides preview-only safe frame, horizon, movement corridor, zones, no-consent area, and static contour guides. Raw video plus manual metadata is stored. |
| Professional-vision research, including Wyss, Baeuerlein & Mahler (2023): video perspective changes what observers notice; noticing and reasoning are distinct. | A single video should not claim to capture "the lesson" neutrally. The app should preserve capture-profile metadata so teachers can interpret what the perspective emphasizes. | `captureProfile` is stored on teaching lessons and exposed to the teacher review queue. |
| Teacher-education video reviews, including Atal, Admiraal & Saab (2023): video supports observation and reflection when the activity is structured. 360 video can add realism but is not required for this pilot. | Do not add 360/VR as a default. Support a lightweight structured workflow first. | The pilot remains standard iPad video with structured profiles and markers. 360/VR is out of scope. |
| Music teacher education literature, including Bautista et al. (2019), Powell (2016), and Economidou Stavrou (2026): video reflection is valuable when framed as inquiry and can otherwise drift toward self-surveillance or surface self-critique. | Language and workflow should emphasize teacher-led inquiry, student participation, musical modelling, feedback, and lesson flow, not appraisal. | Marker kinds focus on phases and pedagogical moments. Docs now frame the feature as reflection-oriented course review. |

## Current Audit Findings

| Finding | Risk | Remediation status |
|---|---|---|
| Filmed lessons were queued for media upload immediately after recording. | This contradicted the local-first/privacy claim that teaching-lesson video remains local until submission. | Fixed: filmed videos now stay pending locally until the student starts submission. |
| Imported lesson videos could miss capture-profile metadata unless the student later filmed inside the app. | The teacher review queue could lack context about the video perspective/focus. | Fixed: teaching-lesson drafts expose a capture-profile picker and imported videos default to `teacher_learner` if unset. |
| `PUT /entries/:entryId/capture-markers` upserted sent markers but kept omitted old markers. | The endpoint behaved like append/update, not an idempotent sync. | Fixed: marker sync now replaces the entry's marker set for the owning student. |
| Server submission allowed a teaching lesson with uploaded audio but no video. | The teaching-lesson workflow could reach review without lesson video evidence. | Fixed: teaching-lesson submission now requires an uploaded video artifact. |
| The service E2E covered practice upload and feedback but not the teaching-lesson video path. | CI could pass while the evidence-aligned lesson workflow was broken. | Fixed: process-level E2E now covers teaching-lesson creation, video upload, marker sync, submission, queue metadata, and entry detail markers. |

## Product Boundaries

- Resonance does not perform face recognition, person detection, pose estimation, emotion analysis, gaze analysis, or automatic teaching-quality scoring.
- Overlays and contours are preview-only aids for camera placement and composition.
- Lesson markers are student-authored metadata for reflection and course review.
- Private course review is the only supported teaching-lesson consent scope.
- Multi-camera, 360 video, VR viewing, research databases, and public video sharing are out of scope for the production pilot.

## Source Links

- Kramer, C., Spicker, S. J., & Kaspar, K. (2023). *Manual zur Erstellung von Unterrichtsvideographien*. <https://kups.ub.uni-koeln.de/65599/1/KramerSpickerKaspar_2023_Videographie_Manual.pdf>
- Wyss, C., Baeuerlein, K., & Mahler, S. (2023). Professional vision depending on video perspective. <https://www.frontiersin.org/journals/education/articles/10.3389/feduc.2023.1282992/full>
- Atal, D., Admiraal, W., & Saab, N. (2023). 360 video in teacher education: systematic review. <https://www.sciencedirect.com/science/article/pii/S0742051X23003372>
- Bautista, A., Tan, C., Wong, J., & Conway, C. (2019). The role of classroom video in music teacher research. <https://www.tandfonline.com/doi/full/10.1080/14613808.2019.1632278>
- Powell, S. R. (2016). The influence of video reflection on preservice music teachers' concerns. <https://journals.sagepub.com/doi/10.1177/0022429415620619>
- Economidou Stavrou, N. (2026). Reflecting on our music teaching and learning practices using video observations. <https://www.frontiersin.org/articles/10.3389/feduc.2026.1725226/full>
