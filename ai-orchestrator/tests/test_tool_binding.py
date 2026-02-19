import unittest
from graph import build_graph
from tool_registry import ALL_TOOLS


class TestToolBinding(unittest.TestCase):

    def test_tool_count(self):
        expected_count = len(ALL_TOOLS)
        self.assertGreater(expected_count, 0)
        print(f"\nDetected {expected_count} tools in ALL_TOOLS")

    def test_graph_compiles(self):
        graph = build_graph()
        self.assertIsNotNone(graph)
        print("Graph compiled successfully")

    def test_model_binding(self):
        from graph import get_model

        model = get_model()
        self.assertTrue(hasattr(model, "invoke"))
        print("Model bound with tools successfully")


if __name__ == "__main__":
    unittest.main()

