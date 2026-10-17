# Local course platform: MVP requirements

Compiled from the Course Studio team (Udemy Course Developer, L&D Agent, Graphic Designer, YouTube Researcher, YouTube Transcriber), Oct 17, 2026.

## 1. Publishing (agents, no browser)
- CLI or API that takes a course folder plus a manifest (YAML/JSON) and creates or updates the course.
- Idempotent: re-running replaces changed items and never duplicates them.
- Draft and published states for courses, sections and lectures.

## 2. Course page
- Title, subtitle, description, learning outcomes, requirements, target audience.
- Course image at 750x422.
- Per-course theme: accent color and a light or dark background.
- One credits page for the whole course, listing every source creator.

## 3. Structure
- Course > sections > lectures, in a set order.
- Section header image at 1920x1080.
- Objective shown at the top of every section and lecture.
- A "recommended next" nudge (sequencing locks come after the MVP).

## 4. Lecture types
- **Video:** MP4 player, .vtt captions, duration, poster frame, "free preview" flag.
- **Article:** Markdown with embedded images.
- **Quiz:** multiple choice, an explanation for every answer, score at the end, images in questions, each question tagged to an objective so results show weak skills.
- **Assignment:** written brief plus a rubric learners check themselves against.

## 5. Inside every lecture
- Interactive transcript from the .vtt: click a line to jump to that moment.
- 1 or 2 ungraded quick-check questions after the video.
- Downloads (PDF, CSV and so on); PDFs open in the browser with a first-page preview.
- "Sources and further watching": linked cards for the source videos and docs, with title, channel and timestamp range.

## 6. Learning support
- Spaced review: before a new section opens, pull 2 or 3 questions from earlier quizzes.
- Search across all transcripts in the course.

## 7. Learner progress
- Mark a lecture complete, resume where you left off, show percent complete per section.

## 8. Media handling
- Fixed image sizes, shown without cropping; smaller sizes generated automatically from one source file.
- PNG, JPG and SVG uploads; SVG stays sharp at every size.
- Alt text required on every image.

## 9. Internal-only material
- A team-only area on each course for transcript packs and research briefs, never shown to learners.

## After the MVP
- Q&A, certificates, ratings, analytics, sequencing locks.
