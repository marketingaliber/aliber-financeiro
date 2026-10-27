# Segurança do Aliber Financeiro

## Quem pode o quê
| Quem | Com o quê | Pode |
|---|---|---|
| Qualquer pessoa na internet | endereço + chave pública (anon), que estão no painel e no programa | Criar uma conta vazia e chamar a sincronização **se tiver a chave de uma loja**. Não lê, não altera e não apaga nada das tabelas. Não consegue apagar tabelas nem o banco. |
| Pessoa com conta mas sem acesso liberado | e-mail e senha | Nada: vê "Falta liberar seu acesso". |
| Usuário liberado numa loja | e-mail e senha | Tudo **daquela loja**: lançar, editar, excluir, restaurar backup. Não vê outras lojas. |
| Equipe Aliber (admin) | e-mail e senha do admin | Todas as lojas, criar lojas, liberar acessos. |
| Computador da loja | chave da loja (24 caracteres) | Enviar vendas/compras dessa loja e baixar o backup dela. |
| Dono da conta Supabase | login do supabase.com | Tudo, inclusive apagar o projeto inteiro. |

As regras ficam no próprio banco (Row Level Security e funções que conferem o acesso); não dependem da tela.
Testado: sem login, `delete`, `select` e `drop table` são recusados.

## O que pode dar errado e a proteção
- **Conta Supabase ou GitHub invadida**: é o único jeito de apagar o banco. Ative a verificação em duas etapas nas duas
  (supabase.com > Account > Security > Multi-factor; github.com > Settings > Password and authentication).
- **Senha do admin vazada**: dá acesso a todas as lojas. Use senha longa e exclusiva.
- **Chave de uma loja vazada**: permite enviar dados falsos e baixar o backup daquela loja. Não guarde a chave em
  conversa ou planilha. Para trocar: no Supabase, SQL Editor:
  `update empresas set chave_sync = encode(gen_random_bytes(12), 'hex') where nome = 'Nome da loja';`
  e cole a chave nova no programa da loja.
- **Usuário da loja apaga coisas sem querer**: restaurar o backup (página Backup do painel ou arquivo do computador da loja).
- **Plano gratuito do Supabase**: não tem backup automático para baixar. Por isso o programa faz o backup diário.
  Projetos gratuitos parados por 7 dias são pausados; a sincronização a cada 15 minutos mantém o projeto ativo.
- **Nunca** coloque no painel, no programa ou no GitHub a chave `service_role` (secret) nem a senha do banco.
- O repositório é público: tem só a chave pública (anon), que é feita para ficar exposta, e o *hash* da senha do técnico.
  Use uma senha de técnico longa (12+ caracteres).
