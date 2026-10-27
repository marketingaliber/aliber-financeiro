# -*- coding: utf-8 -*-
"""
Versões do Aliber Financeiro (igual ao Aliber Print).

As versões ficam nas releases públicas do GitHub (marketingaliber/aliber-financeiro).
A troca de versão é feita pelo técnico, na área protegida pela senha do técnico:
  1. lista as versões publicadas (com as novidades de cada uma)
  2. baixa o AliberFinanceiro-Instalador.exe da versão escolhida
  3. roda o instalador em modo silencioso e fecha o programa; o instalador
     fecha o que ainda estiver aberto, instala por cima e abre a versão nova
Configuração e histórico ficam em %APPDATA%\\Aliber Financeiro e não são tocados.
Também dá para voltar para uma versão mais antiga.
"""
import hashlib
import hmac
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

REPO = "marketingaliber/aliber-financeiro"
INSTALADOR = "AliberFinanceiro-Instalador.exe"
UA = {"User-Agent": "AliberFinanceiro", "Accept": "application/vnd.github+json"}


def _num(v):
    return tuple(int(x) for x in str(v).strip().lstrip("vV").split(".") if x.isdigit())


def instalado():
    """True quando está rodando a partir da instalação (não do .py de desenvolvimento)."""
    return getattr(sys, "frozen", False)


def listar_versoes(atual):
    """Versões publicadas que têm instalador, da mais nova para a mais antiga."""
    req = urllib.request.Request(f"https://api.github.com/repos/{REPO}/releases?per_page=50", headers=UA)
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            dados = json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        if e.code in (403, 429):
            raise RuntimeError("O GitHub limitou as consultas deste computador por alguns minutos. Tente de novo daqui a pouco.") from None
        raise RuntimeError(f"O GitHub respondeu com erro {e.code}.") from None
    except urllib.error.URLError:
        raise RuntimeError("Sem acesso à internet para buscar as versões. Confira a conexão deste computador.") from None
    out = []
    for x in dados:
        if x.get("draft"):
            continue
        a = next((a for a in x.get("assets", []) if a["name"] == INSTALADOR), None)
        if not a:
            continue
        v = x["tag_name"].lstrip("vV")
        out.append({
            "versao": v, "data": (x.get("published_at") or "")[:10], "notas": (x.get("body") or "").strip(),
            "url": a["browser_download_url"], "tamanho_mb": round(a["size"] / 1048576, 1),
            "instalada": v == atual, "mais_nova": _num(v) > _num(atual),
        })
    out.sort(key=lambda d: _num(d["versao"]), reverse=True)
    return out


def baixar(versao, progresso=None):
    """Baixa o instalador da versão para a pasta temporária. Retorna o caminho."""
    destino = os.path.join(tempfile.gettempdir(), f"AliberFinanceiro-Instalador-{versao['versao']}.exe")
    req = urllib.request.Request(versao["url"], headers={"User-Agent": "AliberFinanceiro"})
    with urllib.request.urlopen(req, timeout=60) as r, open(destino + ".parcial", "wb") as f:
        total = int(r.headers.get("Content-Length") or 0)
        lido = 0
        while True:
            bloco = r.read(256 * 1024)
            if not bloco:
                break
            f.write(bloco)
            lido += len(bloco)
            if progresso and total:
                progresso(lido * 100 // total)
    with open(destino + ".parcial", "rb") as f:
        if f.read(2) != b"MZ" or os.path.getsize(destino + ".parcial") < 1_000_000:
            os.remove(destino + ".parcial")
            raise RuntimeError("o arquivo baixado não é um instalador válido")
    os.replace(destino + ".parcial", destino)
    return destino


def ambiente_limpo():
    """Sem as variáveis do .exe atual: a versão nova precisa usar os próprios componentes."""
    env = {k: v for k, v in os.environ.items()
           if not (k.startswith("_PYI") or k.startswith("_MEIPASS") or k in ("TCL_LIBRARY", "TK_LIBRARY"))}
    env["PYINSTALLER_RESET_ENVIRONMENT"] = "1"
    return env


def instalar(caminho):
    """Roda o instalador em silêncio, como programa independente. Quem chama deve fechar o app logo depois."""
    subprocess.Popen([caminho, "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/SP-"],
                     cwd=os.path.dirname(caminho), env=ambiente_limpo(), close_fds=True,
                     creationflags=0x00000008 | 0x00000200)  # desvinculado, grupo de processos novo


# ---------------------------------------------------------------- senha do técnico (a mesma do Aliber Print)
_erros = [0, 0.0]   # tentativas erradas, bloqueado até


def conferir_senha(senha, marca):
    if time.time() < _erros[1]:
        raise RuntimeError("Muitas tentativas erradas. Aguarde um minuto e tente de novo.")
    cfg = (marca or {}).get("senhaTecnico")
    if not cfg:
        raise RuntimeError("A senha do técnico não foi configurada nesta versão.")
    calc = hashlib.pbkdf2_hmac("sha256", str(senha or "").encode("utf-8"), cfg["sal"].encode("utf-8"), int(cfg["iteracoes"]), 32)
    if not hmac.compare_digest(calc, bytes.fromhex(cfg["hash"])):
        _erros[0] += 1
        if _erros[0] >= 5:
            _erros[0], _erros[1] = 0, time.time() + 60
        raise RuntimeError("Senha incorreta.")
    _erros[0] = 0
    return True
