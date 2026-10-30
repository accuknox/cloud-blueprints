import json
import logging
import os
import time
import urllib.error
import urllib.request
from typing import Any

try:
    from jose import jwt
    from jose.exceptions import JWTError
except ModuleNotFoundError:  # pragma: no cover - local test fallback
    jwt = None
    JWTError = Exception


_JWKS_CACHE: dict[str, Any] = {"value": None, "expires_at": 0}
JWKS_CACHE_TTL_SECONDS = 3600
DEFAULT_REQUIRED_CLAIMS = "exp,tenant-id"
logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)


class AuthorizationError(Exception):
    """Raised when the request cannot be authorized."""


def lambda_handler(event: dict[str, Any], _context: Any) -> dict[str, Any]:
    try:
        token = _extract_bearer_token(event)
        claims = _verify_token(token)
        logger.info("authorization succeeded for tenant_id=%s issuer=%s", claims.get("tenant-id"), claims.get("iss"))
        return _allow_response(claims)
    except AuthorizationError as exc:
        logger.warning("authorization denied: %s", exc)
        return _deny_response(str(exc))
    except Exception as exc:  # pragma: no cover - defensive fallback
        logger.exception("unexpected authorization error")
        return _deny_response(f"unexpected authorization error: {exc}")


def _extract_bearer_token(event: dict[str, Any]) -> str:
    headers = event.get("headers") or {}
    authorization = headers.get("authorization") or headers.get("Authorization")
    if not authorization:
        raise AuthorizationError("Authorization header is required")

    parts = authorization.split(" ", 1)
    if len(parts) != 2 or parts[0].lower() != "bearer":
        raise AuthorizationError("Authorization header must be in Bearer token format")
    return parts[1].strip()


def _verify_token(token: str) -> dict[str, Any]:
    if jwt is None:
        raise AuthorizationError("python-jose dependency is required in the Lambda package")

    jwks_url = os.getenv("JWT_JWKS_URL", "").strip()
    expected_issuer = os.getenv("JWT_EXPECTED_ISSUER", "").strip()
    expected_audience = os.getenv("JWT_EXPECTED_AUDIENCE", "").strip()
    expected_subject = os.getenv("JWT_EXPECTED_SUBJECT", "").strip()
    required_token_type = os.getenv("JWT_REQUIRED_TOKEN_TYPE", "access").strip()
    required_claims = _csv_env("JWT_REQUIRED_CLAIMS", DEFAULT_REQUIRED_CLAIMS)
    leeway_seconds = _int_env("JWT_CLOCK_SKEW_SECONDS", 60)

    if not jwks_url:
        raise AuthorizationError("JWT_JWKS_URL is not configured")
    if not expected_issuer:
        raise AuthorizationError("JWT_EXPECTED_ISSUER is not configured")

    header = jwt.get_unverified_header(token)
    algorithm = header.get("alg")
    if algorithm != "RS256":
        raise AuthorizationError(f"unexpected signing algorithm: {algorithm}")

    kid = header.get("kid")
    jwk = _find_jwk(jwks_url, kid)
    decode_kwargs: dict[str, Any] = {"algorithms": ["RS256"], "issuer": expected_issuer}
    options = {
        "require_exp": "exp" in required_claims,
        "require_iat": "iat" in required_claims,
        "require_nbf": "nbf" in required_claims,
        "leeway": leeway_seconds,
    }
    if expected_audience:
        decode_kwargs["audience"] = expected_audience
    else:
        options["verify_aud"] = False
    decode_kwargs["options"] = options

    try:
        claims = jwt.decode(token, key=jwk, **decode_kwargs)
    except JWTError as exc:
        raise AuthorizationError(f"invalid token: {exc}") from exc

    _validate_required_claims(claims, required_claims)
    _validate_temporal_claims(claims, leeway_seconds)

    if required_token_type:
        token_type = claims.get("token_type")
        if token_type != required_token_type:
            raise AuthorizationError(
                f"unexpected token_type: expected {required_token_type}, got {token_type}"
            )

    tenant_id = claims.get("tenant-id")
    if tenant_id is None:
        raise AuthorizationError("tenant-id claim is required")

    if expected_subject:
        subject = claims.get("sub")
        if subject != expected_subject:
            raise AuthorizationError(
                f"unexpected subject: expected {expected_subject}, got {subject}"
            )

   
    return claims


def _validate_required_claims(claims: dict[str, Any], required_claims: list[str]) -> None:
    for claim in required_claims:
        if claims.get(claim) is None:
            raise AuthorizationError(f"{claim} claim is required")


def _validate_temporal_claims(claims: dict[str, Any], leeway_seconds: int) -> None:
    now = int(time.time())
    exp = _optional_int_claim(claims, "exp")
    if exp is not None and exp <= now - leeway_seconds:
        raise AuthorizationError("token has expired")

    nbf = _optional_int_claim(claims, "nbf")
    if nbf is not None and nbf > now + leeway_seconds:
        raise AuthorizationError("token is not valid yet")

    iat = _optional_int_claim(claims, "iat")
    if iat is not None and iat > now + leeway_seconds:
        raise AuthorizationError("token issued-at time is in the future")


def _optional_int_claim(claims: dict[str, Any], claim: str) -> int | None:
    value = claims.get(claim)
    if value is None:
        return None
    try:
        return int(value)
    except (TypeError, ValueError) as exc:
        raise AuthorizationError(f"{claim} claim must be a Unix timestamp") from exc


def _first_present_claim(claims: dict[str, Any], claim_names: list[str]) -> Any:
    for claim_name in claim_names:
        if claims.get(claim_name) is not None:
            return claims[claim_name]
    return None


def _csv_env(name: str, default: str = "") -> list[str]:
    value = os.getenv(name, default)
    return [item.strip() for item in value.split(",") if item.strip()]


def _int_env(name: str, default: int) -> int:
    value = os.getenv(name, "").strip()
    if not value:
        return default
    try:
        return int(value)
    except ValueError as exc:
        raise AuthorizationError(f"{name} must be an integer") from exc


def _fetch_jwks(jwks_url: str) -> dict[str, Any]:
    now = time.time()
    if _JWKS_CACHE["value"] and _JWKS_CACHE["expires_at"] > now:
        return _JWKS_CACHE["value"]

    try:
        with urllib.request.urlopen(jwks_url, timeout=5) as response:
            if response.status != 200:
                raise AuthorizationError(
                    f"failed to fetch JWKS: status {response.status}"
                )
            jwks = json.loads(response.read().decode("utf-8"))
    except (urllib.error.URLError, urllib.error.HTTPError, json.JSONDecodeError) as exc:
        raise AuthorizationError(f"failed to fetch JWKS: {exc}") from exc

    if not isinstance(jwks, dict) or not isinstance(jwks.get("keys"), list):
        raise AuthorizationError("JWKS response does not contain a keys array")

    _JWKS_CACHE["value"] = jwks
    _JWKS_CACHE["expires_at"] = now + JWKS_CACHE_TTL_SECONDS
    return jwks


def _find_jwk(jwks_url: str, kid: str | None) -> dict[str, Any]:
    jwks = _fetch_jwks(jwks_url)
    keys = jwks["keys"]
    fallback_rsa_key: dict[str, Any] | None = None
    for key in keys:
        if key.get("kty") != "RSA":
            continue
        if fallback_rsa_key is None:
            fallback_rsa_key = key
        if kid and key.get("kid") == kid:
            return key
        if not kid and key.get("alg") == "RS256":
            return key
    if not kid and fallback_rsa_key is not None:
        return fallback_rsa_key
    raise AuthorizationError("no matching JWKS key found for token")


def _allow_response(claims: dict[str, Any]) -> dict[str, Any]:
    context = {
        "tenant_id": str(claims.get("tenant-id", "")),
        "issuer": str(claims.get("iss", "")),
        "token_type": str(claims.get("token_type", "")),
    }
    if "sub" in claims:
        context["subject"] = str(claims["sub"])
    if "aud" in claims:
        aud = claims["aud"]
        context["audience"] = aud if isinstance(aud, str) else json.dumps(aud)

    return {
        "isAuthorized": True,
        "context": context,
    }


def _deny_response(reason: str) -> dict[str, Any]:
    return {
        "isAuthorized": False,
        "context": {"reason": reason},
    }
