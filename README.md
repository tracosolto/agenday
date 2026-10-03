# Agenday

Agendamentos mais simples. Cada negócio tem seu perfil, seus serviços, suas cores e uma página para o cliente marcar horário sozinho, com aviso pelo WhatsApp e evento no Google Agenda.

## Links

- App: https://tracosolto.github.io/agenday/
- Barba na Porta (cliente): https://tracosolto.github.io/agenday/#barba-na-porta
- Barba na Porta (painel): https://tracosolto.github.io/agenday/#barba-na-porta/painel

## Como funciona

- `index.html` é o app inteiro. Não há etapa de instalação.
- `schema.sql` cria o banco de dados no Supabase: contas, negócios, clientes e agendamentos, com as regras de quem enxerga o quê.
- Em `index.html`, a linha `var SB={url:'',key:'',...}` liga o app ao servidor. Com `url` e `key` vazios o app roda em modo demonstração, com os dados só no navegador.

## Com o servidor ligado

- Tela inicial com login: e-mail e senha, ou conta do Google.
- Cada conta nova fica aguardando aprovação do administrador antes de usar o painel.
- Cada profissional enxerga só o próprio negócio, seus clientes e sua agenda.
- O cliente agenda sem login, pelo link do negócio. Ele vê apenas os horários livres.
- Nome, logo, cor e modo claro ou escuro são definidos por negócio, em Perfil.

## O que já funciona

- Página do cliente: escolha de serviço, adicionais, local, dia e horário
- Painel: agenda mensal, clientes, serviços, horários e perfil
- Mensagens prontas para o WhatsApp (confirmação, lembrete, cancelamento, pedido de avaliação)
- Google Agenda e planilha da Barba na Porta, por um script na conta do negócio
- Avaliações com nota e comentário
- App instalável no celular

## Próximas etapas

1. Login com a Apple (exige conta Apple Developer)
2. E-mail de recuperação de senha (exige um serviço de envio de e-mails)
3. Cobrança do plano mensal (Pix ou cartão)
4. Confirmação e lembrete automáticos pelo WhatsApp
