// Public Firebase Web config for the arboryx.ai apex landing page.
//
// These values are the Firebase *web app* config — they are public by design
// (Firebase security is enforced by Auth + Firestore rules, not by hiding the
// apiKey). Reused verbatim from the working robotics frontend on the same GCP
// project `marketresearch-agents`. NO secrets belong in this file.
window.FIREBASE_CONFIG = {
  projectId: "marketresearch-agents",
  apiKey: "AIzaSyB9wtP0yNepRyiBTxNqN7adDeOmTJY1HAQ",
  authDomain: "marketresearch-agents.firebaseapp.com",
  appId: "1:891511661510:web:334045fb42facf744008c7",
  databaseId: "(default)",
};
