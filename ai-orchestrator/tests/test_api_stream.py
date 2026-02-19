import unittest
from unittest.mock import patch
from fastapi.testclient import TestClient
from main import APP

client = TestClient(APP)

class TestAPI(unittest.TestCase):

    @patch("graph.get_model")
    def test_chat_endpoint(self, mock_model):
        from langchain_core.messages import AIMessage

        fake_model = mock_model.return_value
        fake_model.bind_tools.return_value = fake_model
        fake_model.invoke.return_value = AIMessage(content="Done")

        response = client.post("/chat", json={"message": "hello"})
        self.assertEqual(response.status_code, 200)
        self.assertIn("Done", response.text)

if __name__ == "__main__":
    unittest.main()

