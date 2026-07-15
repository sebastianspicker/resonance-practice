import { PrismaClient } from '@prisma/client';
import { assertDemoDatabaseUrl, resetDemoData } from './demoFixture.js';

const prisma = new PrismaClient();

async function main() {
  assertDemoDatabaseUrl(process.env.DATABASE_URL);
  await resetDemoData(prisma);
  console.log('Removed all demo_* records from database.');
}

main()
  .catch((err) => {
    console.error('Failed to reset demo fixture data:', err);
    process.exit(1);
  })
  .finally(async () => {
    await prisma.$disconnect();
  });
