FROM python:3.13-slim

WORKDIR /app

RUN pip install --no-cache-dir \
    mysql-connector-python \
    pyyaml \
    flask \
    GitPython

COPY kanban_web.py kanban_mcp.py kanban_export.py git_timeline.py timeline_builder.py ./
COPY templates/ templates/
COPY static/ static/

EXPOSE 5000

CMD ["python3", "kanban_web.py", "--host", "0.0.0.0"]
