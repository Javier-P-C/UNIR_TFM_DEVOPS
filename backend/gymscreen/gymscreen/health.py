"""
Health endpoints for the Kubernetes probes.

The kubelet sends probes to the pod IP, which is not in ALLOWED_HOSTS, so
Django would answer 400. This middleware answers before anything calls
request.get_host() (where ALLOWED_HOSTS is checked), so it must be the
first entry in MIDDLEWARE.

/healthz  liveness: the process is up and serving requests. It never touches
          the database, so a database outage does not make Kubernetes
          restart the pods.
/readyz   readiness: the database answers. While it fails, the pod stops
          receiving traffic but keeps running.
"""

import logging

from django.db import DatabaseError, connection
from django.http import JsonResponse

logger = logging.getLogger(__name__)

LIVENESS_PATH = "/healthz"
READINESS_PATH = "/readyz"


class HealthCheckMiddleware:
    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        if request.path == LIVENESS_PATH:
            return JsonResponse({"status": "ok"})
        if request.path == READINESS_PATH:
            return self._readiness()
        return self.get_response(request)

    @staticmethod
    def _readiness():
        try:
            with connection.cursor() as cursor:
                cursor.execute("SELECT 1")
        except DatabaseError as e:
            logger.warning("Readiness check failed: %s", e)
            return JsonResponse({"status": "unavailable"}, status=503)
        return JsonResponse({"status": "ok"})
