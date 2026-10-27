# -*- coding: utf-8 -*-
"""Envio do resumo para o banco na nuvem (Supabase) da Aliber."""
import json
import urllib.error
import urllib.request

# Dados do projeto Supabase da Aliber (Settings > API). A chave "anon" é pública por
# natureza: sozinha ela não lê nada, só permite chamar a função sincronizar com a
# chave secreta de cada empresa.
SUPABASE_URL = "https://gdoklolbjrnnqcklgjtt.supabase.co"
SUPABASE_ANON = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imdkb2tsb2xianJubnFja2xnanR0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTMwNTY5ODQsImV4cCI6MjEwODYzMjk4NH0.YoBdRMey8JKVYR7HWeTZsRVWxOFq1L94E7nq5qtQYd0"
PAINEL_URL = "https://marketingaliber.github.io/aliber-financeiro/"


def configurado(cfg):
    return bool((cfg.get("supabase_url") or SUPABASE_URL) and (cfg.get("supabase_anon") or SUPABASE_ANON))


def enviar(cfg, resumo):
    url = (cfg.get("supabase_url") or SUPABASE_URL).rstrip("/") + "/rest/v1/rpc/sincronizar"
    anon = cfg.get("supabase_anon") or SUPABASE_ANON
    corpo = json.dumps({"chave": cfg["chave_sync"].strip(), "dados": resumo}).encode("utf-8")
    req = urllib.request.Request(url, data=corpo, method="POST", headers={
        "apikey": anon, "Authorization": "Bearer " + anon,
        "Content-Type": "application/json", "User-Agent": "AliberFinanceiro"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read().decode("utf-8") or "{}")
    except urllib.error.HTTPError as e:
        try:
            msg = json.loads(e.read().decode("utf-8")).get("message")
        except Exception:
            msg = None
        raise RuntimeError(msg or f"erro {e.code} no servidor") from None
    except urllib.error.URLError as e:
        raise RuntimeError(f"sem conexão com a internet ({e.reason})") from None
