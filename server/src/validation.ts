import { CourseRole, PrismaClient } from '@prisma/client';
import { ErrorCodes } from './errorCodes.js';
import { ApiError } from './errors.js';
import { AuthUser } from './types.js';

export function requireField<T>(value: T | undefined | null, name: string) {
  if (value === undefined || value === null) {
    throw new ApiError(400, ErrorCodes.VALIDATION_ERROR, `Missing field: ${name}`);
  }
  return value;
}

/**
 * Validate a client-supplied resource ID.
 * Accepts 1-128 characters of alphanumeric, hyphens, and underscores.
 * Rejects empty strings, overly long IDs, and characters that could
 * cause injection or path-traversal issues.
 */
const CLIENT_ID_REGEX = /^[a-zA-Z0-9_-]{1,128}$/;

export function requireClientId(value: unknown, name: string): string {
  const str = requireString(value, name, { max: 128 });
  if (!CLIENT_ID_REGEX.test(str)) {
    throw new ApiError(
      400,
      ErrorCodes.VALIDATION_ERROR,
      `Invalid ID format: ${name} (must be 1-128 alphanumeric, hyphen, or underscore characters)`
    );
  }
  return str;
}

export function requireString(
  value: unknown,
  name: string,
  options?: { max?: number; minLength?: number }
) {
  if (typeof value !== 'string') {
    throw new ApiError(400, ErrorCodes.VALIDATION_ERROR, `Invalid string: ${name}`);
  }
  const trimmed = value.trim();
  const minLength = options?.minLength ?? 0;
  if (trimmed.length < minLength) {
    throw new ApiError(
      400,
      ErrorCodes.VALIDATION_ERROR,
      `String too short: ${name} (min ${minLength})`
    );
  }
  const max = options?.max ?? 10000;
  if (trimmed.length > max) {
    throw new ApiError(400, ErrorCodes.VALIDATION_ERROR, `String too long: ${name} (max ${max})`);
  }
  return trimmed;
}

export function requireEnum<T extends string>(value: unknown, name: string, allowed: readonly T[]) {
  const str = requireString(value, name) as T;
  if (!allowed.includes(str)) {
    throw new ApiError(400, ErrorCodes.VALIDATION_ERROR, `Invalid enum value: ${name}`);
  }
  return str;
}

export function requireStringArray(value: unknown, name: string, options?: { max?: number }) {
  if (!Array.isArray(value)) {
    throw new ApiError(400, ErrorCodes.VALIDATION_ERROR, `Invalid array: ${name}`);
  }
  const max = options?.max ?? 100;
  if (value.length > max) {
    throw new ApiError(400, ErrorCodes.VALIDATION_ERROR, `Array too large: ${name} (max ${max})`);
  }
  for (const item of value) {
    if (typeof item !== 'string') {
      throw new ApiError(400, ErrorCodes.VALIDATION_ERROR, `Invalid array element: ${name}`);
    }
  }
  return value as string[];
}

const DATE_ONLY_REGEX = /^(\d{4})-(\d{2})-(\d{2})$/;
const DATE_TIME_REGEX =
  /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(\.\d{3})?(Z|([+-])(\d{2}):(\d{2}))$/;

type IsoDateMatch = {
  match: RegExpMatchArray;
  hasTime: boolean;
};

export function requireValidDate(value: unknown, name: string): Date {
  const str = String(value);
  const isoMatch = requireIsoDateMatch(str, name);
  validateIsoDateParts(isoMatch, name);
  const date = new Date(str);
  if (Number.isNaN(date.getTime())) {
    throw new ApiError(400, ErrorCodes.VALIDATION_ERROR, `Invalid date: ${name}`);
  }
  return date;
}

function requireIsoDateMatch(str: string, name: string): IsoDateMatch {
  const dateOnlyMatch = str.match(DATE_ONLY_REGEX);
  if (dateOnlyMatch) {
    return { match: dateOnlyMatch, hasTime: false };
  }

  const dateTimeMatch = str.match(DATE_TIME_REGEX);
  if (dateTimeMatch) {
    return { match: dateTimeMatch, hasTime: true };
  }

  throw new ApiError(
    400,
    ErrorCodes.VALIDATION_ERROR,
    `Invalid date format: ${name}, expected ISO 8601`
  );
}

function validateIsoDateParts(isoMatch: IsoDateMatch, name: string) {
  const year = Number(isoMatch.match[1]);
  const month = Number(isoMatch.match[2]);
  const day = Number(isoMatch.match[3]);
  if (!isValidCalendarDate(year, month, day)) {
    throw new ApiError(400, ErrorCodes.VALIDATION_ERROR, `Invalid date: ${name}`);
  }
  if (isoMatch.hasTime) {
    validateIsoTimeParts(isoMatch.match, name);
    validateIsoOffsetParts(isoMatch.match, name);
  }
}

function validateIsoTimeParts(match: RegExpMatchArray, name: string) {
  const hour = Number(match[4]);
  const minute = Number(match[5]);
  const second = Number(match[6]);
  if (hour > 23 || minute > 59 || second > 59) {
    throw new ApiError(400, ErrorCodes.VALIDATION_ERROR, `Invalid date: ${name}`);
  }
}

function validateIsoOffsetParts(match: RegExpMatchArray, name: string) {
  if (match[8] === 'Z') {
    return;
  }
  const offsetHour = Number(match[10]);
  const offsetMinute = Number(match[11]);
  if (offsetHour > 23 || offsetMinute > 59) {
    throw new ApiError(400, ErrorCodes.VALIDATION_ERROR, `Invalid date: ${name}`);
  }
}

function isValidCalendarDate(year: number, month: number, day: number): boolean {
  if (month < 1 || month > 12 || day < 1 || day > 31) {
    return false;
  }

  const candidate = new Date(Date.UTC(year, month - 1, day));
  return (
    candidate.getUTCFullYear() === year &&
    candidate.getUTCMonth() === month - 1 &&
    candidate.getUTCDate() === day
  );
}

export function requireNumber(
  value: unknown,
  name: string,
  options?: { min?: number; max?: number; integer?: boolean }
) {
  if (typeof value !== 'number' || Number.isNaN(value) || !Number.isFinite(value)) {
    throw new ApiError(400, ErrorCodes.VALIDATION_ERROR, `Invalid number: ${name}`);
  }
  if (options?.integer && !Number.isInteger(value)) {
    throw new ApiError(400, ErrorCodes.VALIDATION_ERROR, `Expected integer: ${name}`);
  }
  if (options?.min !== undefined && value < options.min) {
    throw new ApiError(400, ErrorCodes.VALIDATION_ERROR, `Number too small: ${name}`);
  }
  if (options?.max !== undefined && value > options.max) {
    throw new ApiError(400, ErrorCodes.VALIDATION_ERROR, `Number too large: ${name}`);
  }
  return value;
}

export function requireBoolean(value: unknown, name: string): boolean {
  if (typeof value !== 'boolean') {
    throw new ApiError(400, ErrorCodes.VALIDATION_ERROR, `Invalid boolean: ${name}`);
  }
  return value;
}

export async function requireCourseRole(prisma: PrismaClient, userId: string, courseId: string) {
  const membership = await prisma.membership.findUnique({
    where: { userId_courseId: { userId, courseId } },
  });
  if (!membership) {
    throw new ApiError(403, ErrorCodes.COURSE_ACCESS_DENIED, 'User is not a member of this course');
  }
  return membership.roleInCourse;
}

export async function requireEntryAccess(prisma: PrismaClient, user: AuthUser, entryId: string) {
  const entry = await prisma.practiceEntry.findUnique({ where: { id: entryId } });
  if (!entry) {
    throw new ApiError(404, ErrorCodes.ENTRY_NOT_FOUND, 'Entry not found');
  }
  if (entry.deletedAt) {
    throw new ApiError(410, ErrorCodes.ENTRY_DELETED, 'Entry has been deleted');
  }

  // Use course role for authorization, not global role
  const roleInCourse = await requireCourseRole(prisma, user.id, entry.courseId);

  // Students can only access their own entries
  if (roleInCourse === 'student' && entry.studentId !== user.id) {
    throw new ApiError(403, ErrorCodes.ENTRY_ACCESS_DENIED, 'Entry does not belong to student');
  }

  return { ...entry, roleInCourse };
}

/**
 * Require that the user is a student and the owner of the given entry.
 * Combines course-role check with ownership check in one step.
 *
 * When `knownRole` is provided, the membership lookup is skipped — use this
 * when the caller has already obtained the role (e.g. from `requireEntryAccess`)
 * to avoid a redundant database query.
 */
export async function requireStudentOwner(
  prisma: PrismaClient,
  userId: string,
  entry: { courseId: string; studentId: string },
  action: string,
  knownRole?: CourseRole
) {
  const roleInCourse = knownRole ?? (await requireCourseRole(prisma, userId, entry.courseId));
  if (roleInCourse !== 'student' || entry.studentId !== userId) {
    throw new ApiError(403, ErrorCodes.STUDENT_ONLY, `Only the student owner can ${action}`);
  }
}
