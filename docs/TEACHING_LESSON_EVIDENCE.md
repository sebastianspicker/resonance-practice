# Teaching-Lesson Evidence Basis

This note records the evidence basis and product boundaries for Resonance's teaching-lesson video workflow. It is scoped to video pedagogy and music teacher education, not to legal advice, clinical assessment, or a claim that the current alpha has been institutionally approved.

## Evidence to product decisions

| Evidence | Product implication | Current source alignment |
|---|---|---|
| Kramer, Spicker & Kaspar (2023), *Manual zur Erstellung von Unterrichtsvideographien*, emphasizes defining the purpose, consent, room, camera focus, audio, and later use before recording. | Capture begins with a stated purpose and consent scope, not indiscriminate recording. | Teaching-lesson submission requires private-course-review consent. Capture profiles and manual markers record purpose and focus without automated analysis. |
| Classroom-videography guidance ties camera position and movement to the lesson or research aim and favors stable setups for whole-lesson representation. | Camera overlays should guide composition only; they must not imply scoring or objective interpretation. | Preview-only safe frame, horizon, movement corridor, zones, no-consent area, and contour guides are not stored as analysis. The source stores raw media and manual metadata. |
| Wyss, Baeuerlein & Mahler (2023) distinguish noticing from reasoning and show that video perspective affects what observers notice. | A single perspective is not a neutral or complete record of a lesson. Reviewers need context for what the selected view emphasizes. | The selected `captureProfile` travels with teaching-lesson evidence and is available to the private teacher review flow. |
| Atal, Admiraal & Saab (2023) describe structured uses of video in teacher education; 360-degree video is a possible format, not a requirement for this workflow. | Start with a structured, conventional capture and review loop rather than adding immersive media by default. | The alpha uses standard iPhone/iPad video, capture profiles, and manual markers. |
| Music-teacher-education literature, including Bautista et al. (2019), Powell (2016), and Economidou Stavrou (2026), frames video reflection as useful when connected to inquiry and reflective practice. | Product language should support teacher-led inquiry, student participation, musical modelling, feedback, and lesson flow—not surveillance or appraisal. | Marker kinds and feedback copy focus on phases and pedagogical moments. The workflow stays inside private course review. |

## Implemented safeguards and workflow boundaries

- Teaching-lesson video remains local until the student begins submission.
- Submission requires explicit private-course-review consent and at least one uploaded video artifact.
- Capture-profile metadata gives the reviewer context about the intended perspective.
- Marker synchronization replaces the entry's marker set, avoiding stale omitted markers.
- Server authorization limits private media to the owning student and same-course teachers.
- Process-level service E2E covers lesson creation, upload, marker sync, submission, queue metadata, authorized retrieval, and feedback; screenshots remain visual evidence only.

## Explicit non-capabilities

- No face recognition, person detection, pose estimation, emotion analysis, gaze analysis, or automatic teaching-quality scoring.
- No claim that overlays measure lesson quality or make a video perspective objective.
- No public sharing, research database, multi-camera workflow, 360-degree capture, or VR review.
- No legal determination of consent validity, institutional retention compliance, or production data-processing approval.

## Sources

- Kramer, C., Spicker, S. J., & Kaspar, K. (2023). *Manual zur Erstellung von Unterrichtsvideographien*. <https://kups.ub.uni-koeln.de/65599/1/KramerSpickerKaspar_2023_Videographie_Manual.pdf>
- Wyss, C., Baeuerlein, K., & Mahler, S. (2023). Professional vision depending on video perspective. <https://www.frontiersin.org/journals/education/articles/10.3389/feduc.2023.1282992/full>
- Atal, D., Admiraal, W., & Saab, N. (2023). 360 video in teacher education: systematic review. <https://www.sciencedirect.com/science/article/pii/S0742051X23003372>
- Bautista, A., Tan, C., Wong, J., & Conway, C. (2019). The role of classroom video in music teacher research. <https://www.tandfonline.com/doi/full/10.1080/14613808.2019.1632278>
- Powell, S. R. (2016). The influence of video reflection on preservice music teachers' concerns. <https://journals.sagepub.com/doi/10.1177/0022429415620619>
- Economidou Stavrou, N. (2026). Reflecting on our music teaching and learning practices using video observations. <https://www.frontiersin.org/articles/10.3389/feduc.2026.1725226/full>
