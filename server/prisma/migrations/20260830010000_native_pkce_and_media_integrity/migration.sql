-- Bind native authorization codes to a caller-supplied S256 PKCE challenge.
ALTER TABLE "AuthFlowToken" ADD COLUMN "appCodeChallenge" TEXT;

-- Persist the exact S3 SHA-256 checksum signed for each upload session.
ALTER TABLE "ArtifactUploadSession" ADD COLUMN "checksumSha256" TEXT;
UPDATE "ArtifactUploadSession"
SET "checksumSha256" = ''
WHERE "checksumSha256" IS NULL;
ALTER TABLE "ArtifactUploadSession" ALTER COLUMN "checksumSha256" SET NOT NULL;
