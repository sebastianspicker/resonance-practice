CREATE TYPE "CaptureProfile" AS ENUM (
    'room_overview',
    'teacher_learner',
    'instrument_closeup',
    'ensemble_group',
    'group_work'
);

CREATE TYPE "CaptureMarkerKind" AS ENUM (
    'phase_setup',
    'phase_modeling',
    'phase_guided_practice',
    'phase_student_work',
    'phase_feedback',
    'phase_reflection',
    'moment_question',
    'moment_musical_model',
    'moment_student_response',
    'moment_transition',
    'privacy_note'
);

ALTER TABLE "PracticeEntry"
ADD COLUMN "captureProfile" "CaptureProfile";

CREATE TABLE "CaptureMarker" (
    "id" TEXT NOT NULL,
    "entryId" TEXT NOT NULL,
    "artifactId" TEXT NOT NULL,
    "studentId" TEXT NOT NULL,
    "timeSeconds" INTEGER NOT NULL,
    "kind" "CaptureMarkerKind" NOT NULL,
    "note" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "CaptureMarker_pkey" PRIMARY KEY ("id")
);

CREATE INDEX "CaptureMarker_entryId_idx" ON "CaptureMarker" ("entryId");
CREATE INDEX "CaptureMarker_artifactId_idx" ON "CaptureMarker" ("artifactId");
CREATE INDEX "CaptureMarker_studentId_idx" ON "CaptureMarker" ("studentId");

ALTER TABLE "CaptureMarker"
ADD CONSTRAINT "CaptureMarker_entryId_fkey"
FOREIGN KEY ("entryId") REFERENCES "PracticeEntry" ("id")
ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE "CaptureMarker"
ADD CONSTRAINT "CaptureMarker_artifactId_fkey"
FOREIGN KEY ("artifactId") REFERENCES "Artifact" ("id")
ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE "CaptureMarker"
ADD CONSTRAINT "CaptureMarker_studentId_fkey"
FOREIGN KEY ("studentId") REFERENCES "User" ("id")
ON DELETE CASCADE ON UPDATE CASCADE;
