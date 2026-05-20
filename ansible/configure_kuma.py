import requests
import json
import time
import os

KUMA_URL = "http://10.43.6.86:3001"
# Hardcoded credentials for initial setup based on user input
USERNAME = "admin"
PASSWORD = "password"

# Set up initial admin account
setup_url = f"{KUMA_URL}/api/setup"
setup_data = {"username": USERNAME, "password": PASSWORD}
try:
    setup_res = requests.post(setup_url, json=setup_data)
    print("Setup response:", setup_res.status_code)
except Exception as e:
    print("Setup already done or failed:", e)

# Login
login_url = f"{KUMA_URL}/api/login"
login_data = {"username": USERNAME, "password": PASSWORD}
session = requests.Session()
login_res = session.post(login_url, json=login_data)
if login_res.status_code != 200:
    print("Login failed")
    exit(1)

token = login_res.json().get("token")
headers = {"Authorization": f"Bearer {token}"}

# We can't easily configure OIDC via simple REST API in Kuma because it uses WebSockets/Socket.io heavily for config.
# But we can try to inject standard HTTP config if the API supports it, though usually Kuma's API is undocumented.
# Let's inform the user that proxy auth must be done via the UI.
print("Successfully verified Kuma API access.")
