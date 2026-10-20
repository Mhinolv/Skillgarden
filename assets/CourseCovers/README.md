# Course covers

Editable 1600 × 900 SVG art for the four courses published in the local library:

| Course ID | Art | Alt text |
| --- | --- | --- |
| `n8n-agents-course` | Coral workflow on plum | AI Agents in n8n, with coral workflow nodes on a plum background. |
| `inside-the-checkpoint` | Blue model-weight grid | Inside the Checkpoint, with a blue grid of model weights. |
| `sample-course` | Notebook and leafy branch | Local Course Basics, with a notebook and leafy branch on pale green. |
| `interactive-course` | Numbered tiles and pointer | Interactive Course Basics, with three colorful numbered tiles and a pointer. |

Render PNG files with Apple's SVG renderer:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" swift scripts/render_course_covers.swift
```

Output goes to `build/course-covers/`. An optional argument changes the output folder.
The two full courses use these PNGs as `media/course.png`. The demo fixtures use
SVG copies as `media/course.svg`. After editing demo art, copy it to the matching
`Tests/Fixtures/<course-id>/media/course.svg` too.

To update a course, copy the art to its source folder, set `course_image.alt` to
the text above, and run `skillgarden publish <course-folder>`. Use the publisher
so it refreshes raster derivatives and keeps learner progress. Do not edit the
library database or its image snapshots by hand.
