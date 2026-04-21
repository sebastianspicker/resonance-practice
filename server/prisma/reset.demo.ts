import { PrismaClient } from '@prisma/client';
import { resetDemoData } from './demoFixture.js';

const prisma = new PrismaClient();

async function main() {
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
