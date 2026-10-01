-- Add issuer-scoped identities and bind production OIDC attempts to one browser.
ALTER TABLE "AuthFlowToken"
  ADD COLUMN "browserBindingHash" TEXT,
  ADD COLUMN "nonceHash" TEXT,
  ADD COLUMN "verifierHash" TEXT;

CREATE TABLE "ExternalIdentity" (
  "id" TEXT NOT NULL,
  "issuer" TEXT NOT NULL,
  "subject" TEXT NOT NULL,
  "userId" TEXT NOT NULL,
  "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" TIMESTAMP(3) NOT NULL,
  CONSTRAINT "ExternalIdentity_pkey" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX "ExternalIdentity_issuer_subject_key" ON "ExternalIdentity"("issuer", "subject");
CREATE INDEX "ExternalIdentity_userId_idx" ON "ExternalIdentity"("userId");
ALTER TABLE "ExternalIdentity"
  ADD CONSTRAINT "ExternalIdentity_userId_fkey"
  FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE CASCADE ON UPDATE CASCADE;
