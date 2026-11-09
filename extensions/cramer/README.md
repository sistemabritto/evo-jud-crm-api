# Aviso de falha da IA — Cramer

Patch isolado para a extensão `native_replies.rb` já montada nos serviços
`evocrm_evocrm_crm` e `evocrm_evocrm_crm_sidekiq`. Não altera a imagem nem a stack.

Gere o artefato a partir da cópia atual da VPS, sem substituir outras extensões:

```sh
python3 extensions/cramer/build_failure_handoff.py BASELINE.rb OUTPUT.rb
ruby spec/extensions/cramer/failure_handoff_test.rb extensions/cramer/failure_handoff.rb
```

Na VPS, validar sintaxe com o Ruby da imagem existente, conferir SHA da baseline,
criar backup, gravar com `cat OUTPUT.rb > native_replies.rb` (preserva o inode do
bind mount) e reiniciar somente CRM e Sidekiq. Não usar rename sobre o bind mount.
Rollback recomendado: restaurar `native_replies.rollback_safe.rb` do backup com
`cat`, reiniciar os mesmos dois serviços e
verificar `/health/live` e `/health/ready`. Restaurar o código não desfaz as
atribuições/notas/etiquetas já registradas. O artefato de rollback seguro mantém somente as barreiras e a devolução explícita
para conversas já bloqueadas. O backup original exato também está disponível,
mas isoladamente não conhece `cramer_failure_human_required`.

## Classificação conservadora

Contato precisa ser `lead` ou `customer` **e** ter a etiqueta existente `cliente-ativo`
ou a confirmação explícita
`custom_attributes.cramer_failure_notice_audience` igual a `cliente` ou `lead`.
Esse atributo deve refletir revisão humana no CRM. O patch não preenche esse
atributo e não promove contatos desconhecidos. Mesmo com confirmação, nega
outros canais, equipe (etiquetas, usuários, nomes e telefone interno), opt-out,
marcadores comerciais/verificados/automáticos e nomes comerciais conhecidos.
Na ausência dessas evidências positivas, nenhuma mensagem pública é criada. A transferência,
nota privada e bloqueio permanecem. E-mail sempre fica sem aviso público.

## Persistência e retomada

A trava `Conversation#with_lock` protege a decisão, contador, transferência, nota e
criação da mensagem na mesma transação. `cramer_failure_notice_claimed_at` permanece
pela vida da conversa, inclusive quando a decisão inicial foi suprimir o aviso.
Um aviso antigo já registrado na conversa também impede novo aviso público.
Cada entrega tem reserva persistente anterior ao I/O: falha ambígua de transporte
não repete o aviso, podendo perder uma entrega. Respostas antigas enfileiradas são
barradas no SendReplyJob; avisos legados enfileirados são convertidos em handoff.

Somente `return_to_bot!`, executado com `Current.user` humano, remove
`cramer_failure_human_required`; mudar status ou remover etiqueta não libera.
A etiqueta `falha-ia` permanece para auditoria. Em nova falha, volta ao humano sem
repetir aviso. Se André não pertence à equipe atual, a equipe é removida para o
callback nativo não substituir o responsável exigido.

O postback atual traz o texto de falha sem distinguir timeout de outro erro.
O log usa `runtime_failure_or_timeout_unspecified`, IDs e nome estático do agente,
sem payload, mensagem de exceção, credencial ou dados pessoais do contato.
