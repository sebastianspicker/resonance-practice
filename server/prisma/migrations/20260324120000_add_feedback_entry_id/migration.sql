-- AlterTable
ALTER TABLE "Feedback" ADD COLUMN "entryId" TEXT;

-- CreateIndex
CREATE INDEX "Feedback_entryId_idx" ON "Feedback" ("entryId");

-- AddForeignKey
ALTER TABLE "Feedback" ADD CONSTRAINT "Feedback_entryId_fkey" FOREIGN KEY ("entryId") REFERENCES "PracticeEntry" ("id") ON DELETE CASCADE ON UPDATE CASCADE;
