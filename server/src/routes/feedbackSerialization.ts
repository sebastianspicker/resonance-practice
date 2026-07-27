/** Stable response shaping for feedback lists shared by HTTP route variants. */
type FeedbackListItem = {
  id: string;
  targetType: string;
  targetId: string | null;
  teacherId: string;
  createdAt: Date;
  status: string;
  commentsText: string;
  markers: unknown;
  teacher: { displayName: string };
};

export function serializeFeedback(feedback: FeedbackListItem[], includeTeacherId = false) {
  return feedback.map((item) => ({
    id: item.id,
    targetType: item.targetType,
    targetId: item.targetId,
    ...(includeTeacherId ? { teacherId: item.teacherId } : {}),
    teacherName: item.teacher.displayName,
    createdAt: item.createdAt,
    status: item.status,
    commentsText: item.commentsText,
    markers: item.markers,
  }));
}
