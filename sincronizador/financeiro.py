# -*- coding: utf-8 -*-
"""
Aliber Financeiro - sincronizador (fica no computador do cliente, junto do PDV+).

Lê as vendas do PDV+ (somente leitura) e envia um resumo diário para o painel online,
onde o dono vê a DRE e lança fornecedores e contas a pagar.
"""
import json
import os
import queue
import sys
import threading
import webbrowser
from datetime import date, datetime, timedelta

import tkinter as tk
from tkinter import ttk, messagebox, filedialog

import atualizador
import nuvem
import resumo as R

APP_NOME = "Aliber Financeiro"
VERSAO = "1.0"
VERMELHO = "#D7262B"
AZUL = "#1B4FA0"

if getattr(sys, "frozen", False):
    PASTA = os.path.dirname(sys.executable)
    RECURSOS = getattr(sys, "_MEIPASS", PASTA)
else:
    PASTA = os.path.dirname(os.path.abspath(__file__))
    RECURSOS = PASTA
ARQ_CONFIG = os.path.join(PASTA, "financeiro_config.json")
ARQ_LOG = os.path.join(PASTA, "financeiro_log.txt")

DIAS_REENVIO = 45          # a cada sincronização reenvia os últimos 45 dias (pega cancelamentos tardios)

CONFIG_PADRAO = {
    "db_path": R.DB_PADRAO,
    "chave_sync": "",
    "intervalo_min": 15,
    "supabase_url": "",
    "supabase_anon": "",
    "ultima_sync": "",
    "historico_enviado": False,
}


def carregar_config():
    cfg = dict(CONFIG_PADRAO)
    try:
        with open(ARQ_CONFIG, encoding="utf-8") as f:
            cfg.update(json.load(f))
    except (OSError, ValueError):
        pass
    return cfg


def salvar_config(cfg):
    with open(ARQ_CONFIG, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)


def brl(v):
    return ("R$ {:,.2f}".format(v)).replace(",", "X").replace(".", ",").replace("X", ".")


def registrar(msg):
    linha = f"{datetime.now():%d/%m/%Y %H:%M:%S}  {msg}"
    try:
        with open(ARQ_LOG, "a", encoding="utf-8") as f:
            f.write(linha + "\n")
    except OSError:
        pass
    return linha


def sincronizar(cfg, tudo=False):
    """Monta e envia o resumo. Retorna (texto, resposta). Lança RuntimeError com mensagem amigável."""
    if not os.path.exists(cfg["db_path"]):
        raise RuntimeError("banco do PDV+ não encontrado. Ajuste o caminho em Configurações.")
    if not cfg.get("chave_sync", "").strip():
        raise RuntimeError("falta a chave da empresa. Coloque em Configurações.")
    if not nuvem.configurado(cfg):
        raise RuntimeError("endereço da nuvem não configurado nesta versão.")
    primeira, ultima = R.periodo_disponivel(cfg["db_path"])
    hoje = date.today()
    if not primeira:
        primeira = ultima = hoje
    if tudo or not cfg.get("historico_enviado"):
        ini = primeira
    else:
        ini = max(primeira, hoje - timedelta(days=DIAS_REENVIO))
    fim = max(hoje, ultima)
    res = R.montar(cfg["db_path"], ini, fim, VERSAO)
    t = R.totais(res)
    resp = nuvem.enviar(cfg, res)
    texto = (f"{ini:%d/%m/%Y} a {fim:%d/%m/%Y}: {t['vendas']} vendas, {brl(t['faturamento'])} "
             f"enviados para {resp.get('empresa', 'a nuvem')}")
    return texto, resp


# ---------------------------------------------------------------- iniciar com o Windows
CHAVE_RUN = r"Software\Microsoft\Windows\CurrentVersion\Run"


def inicia_com_windows():
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, CHAVE_RUN) as k:
            winreg.QueryValueEx(k, APP_NOME)
            return True
    except Exception:
        return False


def definir_inicio_windows(ligar):
    import winreg
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, CHAVE_RUN, 0, winreg.SET_VALUE) as k:
        if ligar:
            winreg.SetValueEx(k, APP_NOME, 0, winreg.REG_SZ, f'"{sys.executable}" --minimizado')
        else:
            try:
                winreg.DeleteValue(k, APP_NOME)
            except FileNotFoundError:
                pass


# ---------------------------------------------------------------- janela
class App:
    def __init__(self, root, minimizado=False):
        self.root = root
        self.cfg = carregar_config()
        self.fila = queue.Queue()
        self.rodando = False
        self.proxima = None
        root.title(f"{APP_NOME} {VERSAO}")
        root.geometry("640x470")
        root.minsize(560, 420)
        root.configure(bg="white")
        try:
            root.iconbitmap(os.path.join(RECURSOS, "aliber.ico"))
        except Exception:
            pass

        topo = tk.Frame(root, bg=AZUL)
        topo.pack(fill="x")
        tk.Label(topo, text="Aliber", fg=VERMELHO, bg=AZUL, font=("Segoe UI", 18, "bold")).pack(side="left", padx=(16, 4), pady=8)
        tk.Label(topo, text="Financeiro", fg="white", bg=AZUL, font=("Segoe UI", 18)).pack(side="left", pady=8)
        tk.Label(topo, text=f"v{VERSAO}", fg="#C8D6F0", bg=AZUL, font=("Segoe UI", 9)).pack(side="right", padx=12)

        info = tk.Frame(root, bg="white")
        info.pack(fill="x", padx=16, pady=(14, 6))
        self.lbl = {}
        for i, (k, rot) in enumerate([("banco", "Banco do PDV+"), ("empresa", "Empresa"),
                                       ("ultima", "Última sincronização"), ("proxima", "Próxima")]):
            tk.Label(info, text=rot + ":", bg="white", fg="#555", font=("Segoe UI", 10)).grid(row=i, column=0, sticky="w", pady=2)
            self.lbl[k] = tk.Label(info, text="-", bg="white", font=("Segoe UI", 10, "bold"), anchor="w", justify="left", wraplength=440)
            self.lbl[k].grid(row=i, column=1, sticky="w", padx=10, pady=2)

        bot = tk.Frame(root, bg="white")
        bot.pack(fill="x", padx=16, pady=8)
        self.bt_sync = tk.Button(bot, text="  SINCRONIZAR AGORA  ", bg=VERMELHO, fg="white", relief="flat",
                                 font=("Segoe UI", 10, "bold"), command=lambda: self.iniciar_sync(False))
        self.bt_sync.pack(side="left")
        ttk.Button(bot, text="Abrir painel", command=lambda: webbrowser.open(nuvem.PAINEL_URL)).pack(side="left", padx=8)
        ttk.Button(bot, text="Configurações", command=self.configuracoes).pack(side="left")

        self.var_ini = tk.BooleanVar(value=inicia_com_windows())
        ttk.Checkbutton(root, text="Abrir sozinho quando o Windows ligar (recomendado)", variable=self.var_ini,
                        command=self.trocar_inicio).pack(anchor="w", padx=16)

        tk.Label(root, text="Acontecimentos", bg="white", fg=AZUL, font=("Segoe UI", 10, "bold")).pack(anchor="w", padx=16, pady=(10, 0))
        self.txt = tk.Text(root, height=8, font=("Consolas", 9), relief="solid", bd=1, wrap="word")
        self.txt.pack(fill="both", expand=True, padx=16, pady=(2, 14))
        self.txt.configure(state="disabled")

        self.atualizar_status()
        self.root.after(200, self.processar_fila)
        self.root.after(1500, self.verificar_atualizacao)
        self.root.after(3000, lambda: self.iniciar_sync(False, automatico=True))
        if minimizado:
            root.iconify()

    # ---- interface
    def log(self, msg):
        linha = registrar(msg)
        self.txt.configure(state="normal")
        self.txt.insert("end", linha + "\n")
        self.txt.see("end")
        self.txt.configure(state="disabled")

    def atualizar_status(self):
        c = self.cfg
        if os.path.exists(c["db_path"]):
            self.lbl["banco"].config(text="encontrado", fg="#1E7B34")
        else:
            self.lbl["banco"].config(text="NÃO encontrado (ajuste em Configurações)", fg=VERMELHO)
        self.lbl["empresa"].config(text=c.get("empresa_nome") or ("chave não configurada" if not c.get("chave_sync") else "-"),
                                   fg="#222" if c.get("chave_sync") else VERMELHO)
        u = c.get("ultima_sync")
        self.lbl["ultima"].config(text=datetime.fromisoformat(u).strftime("%d/%m/%Y %H:%M") if u else "nunca", fg="#222")
        self.lbl["proxima"].config(text=self.proxima.strftime("%H:%M") if self.proxima else "-", fg="#222")

    def trocar_inicio(self):
        try:
            definir_inicio_windows(self.var_ini.get())
        except Exception as e:
            messagebox.showerror(APP_NOME, f"Não consegui alterar: {e}")
            self.var_ini.set(inicia_com_windows())

    # ---- sincronização
    def agendar(self):
        minutos = max(5, int(self.cfg.get("intervalo_min") or 15))
        self.proxima = datetime.now() + timedelta(minutes=minutos)
        self.root.after(minutos * 60 * 1000, lambda: self.iniciar_sync(False, automatico=True))
        self.atualizar_status()

    def iniciar_sync(self, tudo, automatico=False):
        if self.rodando:
            return
        if automatico and (not self.cfg.get("chave_sync") or not os.path.exists(self.cfg["db_path"])):
            self.agendar()
            return
        self.rodando = True
        self.bt_sync.config(state="disabled", text="  ENVIANDO...  ")
        cfg = dict(self.cfg)

        def trabalho():
            try:
                texto, resp = sincronizar(cfg, tudo)
                self.fila.put(("ok", texto, resp))
            except Exception as e:
                self.fila.put(("erro", str(e), None))
        threading.Thread(target=trabalho, daemon=True).start()

    def processar_fila(self):
        try:
            while True:
                tipo, texto, resp = self.fila.get_nowait()
                if tipo == "ok":
                    self.cfg["ultima_sync"] = datetime.now().isoformat(timespec="seconds")
                    self.cfg["historico_enviado"] = True
                    if resp and resp.get("empresa"):
                        self.cfg["empresa_nome"] = resp["empresa"]
                    salvar_config(self.cfg)
                    self.log("OK  " + texto)
                elif tipo == "erro":
                    self.log("ERRO  " + texto)
                elif tipo == "atualizacao":
                    self.oferecer_atualizacao(resp)
                if tipo in ("ok", "erro"):
                    self.rodando = False
                    self.bt_sync.config(state="normal", text="  SINCRONIZAR AGORA  ")
                    self.agendar()
        except queue.Empty:
            pass
        self.root.after(300, self.processar_fila)

    # ---- atualização automática
    def verificar_atualizacao(self):
        atualizador.limpar_antigos()
        if not atualizador.pode_se_atualizar():
            return

        def trabalho():
            try:
                info = atualizador.buscar(VERSAO)
                if info:
                    self.fila.put(("atualizacao", "", info))
            except Exception:
                pass
        threading.Thread(target=trabalho, daemon=True).start()

    def oferecer_atualizacao(self, info):
        self.log(f"Versão nova disponível: {info['versao']}. Atualizando...")
        try:
            atualizador.instalar(info)
            self.root.after(500, self.root.destroy)
        except Exception as e:
            self.log(f"ERRO ao atualizar: {e}")

    # ---- configurações
    def configuracoes(self):
        w = tk.Toplevel(self.root)
        w.title("Configurações")
        w.configure(bg="white")
        w.transient(self.root)
        w.grab_set()
        f = tk.Frame(w, bg="white")
        f.pack(padx=16, pady=14, fill="both")
        campos = {}

        def linha(r, rot, chave, largura=52, dica=None):
            tk.Label(f, text=rot, bg="white", font=("Segoe UI", 10)).grid(row=r * 2, column=0, sticky="w", pady=(8, 0))
            e = ttk.Entry(f, width=largura)
            e.insert(0, str(self.cfg.get(chave) or ""))
            e.grid(row=r * 2 + 1, column=0, sticky="we")
            campos[chave] = e
            if dica:
                tk.Label(f, text=dica, bg="white", fg="#777", font=("Segoe UI", 8)).grid(row=r * 2 + 1, column=1, sticky="w", padx=6)
            return e

        linha(0, "Banco do PDV+ (navi_db.db)", "db_path")

        def procurar():
            p = filedialog.askopenfilename(parent=w, filetypes=[("Banco do PDV+", "*.db"), ("Todos", "*.*")])
            if p:
                campos["db_path"].delete(0, "end")
                campos["db_path"].insert(0, os.path.normpath(p))
        ttk.Button(f, text="Procurar...", command=procurar).grid(row=1, column=1, padx=6)
        linha(1, "Chave da empresa (vem do painel, tela Administração)", "chave_sync")
        linha(2, "Sincronizar a cada (minutos)", "intervalo_min", 8, "mínimo 5")
        if not (nuvem.SUPABASE_URL and nuvem.SUPABASE_ANON):
            linha(3, "Endereço da nuvem (Supabase URL)", "supabase_url")
            linha(4, "Chave pública da nuvem (anon)", "supabase_anon")

        rod = tk.Frame(w, bg="white")
        rod.pack(fill="x", padx=16, pady=(0, 14))

        def salvar():
            for k, e in campos.items():
                v = e.get().strip()
                if k == "intervalo_min":
                    try:
                        v = max(5, int(v))
                    except ValueError:
                        v = 15
                if k == "chave_sync" and v != self.cfg.get("chave_sync"):
                    self.cfg["historico_enviado"] = False      # empresa nova: manda o histórico todo
                    self.cfg["empresa_nome"] = ""
                self.cfg[k] = v
            salvar_config(self.cfg)
            self.atualizar_status()
            w.destroy()
            self.iniciar_sync(False)

        def reenviar():
            if messagebox.askyesno(APP_NOME, "Reenviar todas as vendas do PDV+ desde o início?", parent=w):
                w.destroy()
                self.iniciar_sync(True)
        ttk.Button(rod, text="Reenviar histórico completo", command=reenviar).pack(side="left")
        tk.Button(rod, text="  SALVAR  ", bg=AZUL, fg="white", relief="flat", font=("Segoe UI", 10, "bold"),
                  command=salvar).pack(side="right")


def main():
    args = sys.argv[1:]
    # Linha de comando (testes e suporte):
    #   --exportar=arquivo.json [--db=caminho]   grava o resumo completo sem enviar
    #   --teste                                  autoteste do .exe (usado na publicação)
    for a in args:
        if a.startswith("--exportar="):
            cfg = carregar_config()
            db = next((x.split("=", 1)[1] for x in args if x.startswith("--db=")), cfg["db_path"])
            ini, fim = R.periodo_disponivel(db)
            res = R.montar(db, ini or date.today(), fim or date.today(), VERSAO)
            with open(a.split("=", 1)[1], "w", encoding="utf-8") as f:
                json.dump(res, f, ensure_ascii=False)
            return 0
        if a == "--teste":
            import testes.teste_resumo as t
            return t.rodar()
    root = tk.Tk()
    App(root, minimizado="--minimizado" in args)
    root.mainloop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
