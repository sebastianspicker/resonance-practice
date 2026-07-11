CREATE TYPE "EntryKind" AS ENUM ('practice', 'teaching_lesson');
CREATE TYPE "ConsentScope" AS ENUM ('private_course_review');

ALTER TABLE "PracticeEntry"
ADD COLUMN "kind" "EntryKind" NOT NULL DEFAULT 'practice',
ADD COLUMN "consentConfirmedAt" TIMESTAMP(3),
ADD COLUMN "consentScope" "ConsentScope";
