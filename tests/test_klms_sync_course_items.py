import sys
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_DIR / "src" / "python"))

import klms_sync  # noqa: E402


def course_page(html: str) -> dict[str, str]:
    return {
        "html": html,
        "requestedUrl": "https://klms.kaist.ac.kr/course/view.php?id=100001",
        "title": "강좌: Example Course",
    }


class CourseItemParsingTests(unittest.TestCase):
    def test_ignored_dashboard_course_is_not_collected(self) -> None:
        dashboard = klms_sync.DashboardParseResult(
            status="ok",
            items=[
                klms_sync.DashboardItem(
                    url="https://klms.kaist.ac.kr/mod/assign/view.php?id=100002",
                    title="[과제] Homework 8",
                    course="KLMS",
                    schedule="~2026.05.10",
                    item_type="assign",
                )
            ],
        )

        items = klms_sync.collect_candidate_items(dashboard, [])

        self.assertEqual(items, [])

    def test_lecture_upload_notice_is_not_tracked_as_assignment(self) -> None:
        html = """
        <html><body>
          <li class="activity url modtype_url" id="module-100003">
            <div class="activityinstance">
              <a href="https://klms.kaist.ac.kr/mod/url/view.php?id=100003">
                <span class="instancename">
                  NO Lecture video - 25.04.23
                  (Will be recorded and uploaded by April 29, 23:59)
                  <span class="accesshide">URL</span>
                </span>
              </a>
            </div>
          </li>
        </body></html>
        """

        items = klms_sync.parse_course_page(course_page(html))

        self.assertEqual(items, [])

    def test_url_quiz_with_due_date_is_still_tracked(self) -> None:
        html = """
        <html><body>
          <li class="activity url modtype_url" id="module-100004">
            <div class="activityinstance">
              <a href="https://klms.kaist.ac.kr/mod/url/view.php?id=100004">
                <span class="instancename">
                  Nano Quiz - 25.04.21(Mon)<span class="accesshide">URL</span>
                </span>
              </a>
            </div>
            <div class="contentafterlink">
              <p>Due Date: Monday, May 4, 11:59:59 PM.</p>
            </div>
          </li>
        </body></html>
        """

        items = klms_sync.parse_course_page(course_page(html))

        self.assertEqual(len(items), 1)
        self.assertEqual(items[0].url, "https://klms.kaist.ac.kr/mod/url/view.php?id=100004")
        self.assertTrue(items[0].schedule)


if __name__ == "__main__":
    unittest.main()
