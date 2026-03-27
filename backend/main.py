from fastapi import FastAPI

app = FastAPI(title="Project Backend")

@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}

