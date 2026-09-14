import sys
import json
import base64


def decode_jwt_part(part):
    """Decode a base64url-encoded JWT part."""
    padding = 4 - len(part) % 4
    if padding != 4:
        part += '=' * padding
    return base64.urlsafe_b64decode(part)


def main():
    """Decode JWT from stdin and print claims."""
    jwt = sys.stdin.read().strip()
    parts = jwt.split('.')
    if len(parts) != 3:
        print(f"JWT has {len(parts)} parts, expected 3")
        sys.exit(1)
    try:
        header = json.loads(decode_jwt_part(parts[0]))
        print("JWT header:")
        for key, value in header.items():
            print(f"  {key}: {value}")
        payload = json.loads(decode_jwt_part(parts[1]))
        print("JWT payload claims:")
        for key, value in payload.items():
            print(f"  {key}: {value}")
    except Exception as e:
        print(f"Error decoding JWT: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()