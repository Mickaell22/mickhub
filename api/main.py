from fastapi import FastAPI

app = FastAPI(title="MickHub API")


@app.get("/health")
def health():
    return {"ok": True}
