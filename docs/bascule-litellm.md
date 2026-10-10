# Remplacer LiteLLM par le point d'entrée

À faire par l'utilisateur : la bascule arrête le service dont dépend Watslog et demande les clés des API distantes. Chaque étape se vérifie avant la suivante ; le retour arrière est en bas.

## Avant

1. **Clés des API distantes.** Dans l'app, **Point d'entrée → API distantes → Ajouter la clé…** pour `deepseek` et `cline` (ou `llmarium provider set-key deepseek`, saisie invisible). Les clés vont dans le trousseau de session ; l'app ne lit jamais le `.env` de LiteLLM. La première lecture par l'app, puis par `llmarium`, peut demander une autorisation du trousseau (binaires signés séparément) : choisir « Toujours autoriser ».
2. **Noms.** Les six noms de `litellm-config.yaml` sont importés (`llmarium proxy import-litellm ~/Dev/server/llm-stack/litellm-config.yaml`). Vérifier dans **Point d'entrée → Noms stables** :
   - `qwen3.8-27b-abliterated`, `granite-embedding` : servis par oMLX ;
   - `deepseek-v4-pro`, `deepseek-v4-flash-api` : DeepSeek, une fois la clé ajoutée ;
   - `cline/*` : Cline, une fois la clé ajoutée ;
   - `ds4-flash`, `qwen3.6-mtplx`, `qwen3.8-flash-next-mlx-serve` : « Cible absente » tant que ds4, le MTPLX correspondant ou mlx-serve ne tournent pas. C'est déjà le cas avec LiteLLM aujourd'hui (ports 8000, 8001 et 11234 fermés). Ces noms restent **locaux** : ils ne partent jamais vers une API distante, même si l'identifiant existe chez DeepSeek.
3. **Essai à côté de LiteLLM**, sur le port de test (18099) :

```bash
curl -s -H "Authorization: Bearer litellm:local" http://localhost:18099/v1/models
```

## Bascule

4. Arrêter seulement LiteLLM (SearXNG et Postgres ne sont pas concernés) :

```bash
docker compose -f ~/Dev/server/llm-stack/docker-compose.yml stop litellm
```

5. Passer le point d'entrée sur le port 4000, puis couper et rallumer son interrupteur dans l'app :

```bash
llmarium proxy port 4000
```

6. Vérifier comme Watslog le fait (`GET /v1/models`, puis un chat) :

```bash
curl -s -H "Authorization: Bearer litellm:local" http://localhost:4000/v1/models
```

```bash
curl -s http://localhost:4000/v1/chat/completions -H "Content-Type: application/json" -H "Authorization: Bearer litellm:local" -d '{"model":"qwen3.8-27b-abliterated","max_tokens":10,"messages":[{"role":"user","content":"ok ?"}]}'
```

7. Dans Watslog, lancer sa vérification de configuration ; puis une proposition avec Pi (modèle `qwen3.8-flash-next-mlx-serve` : lancer d'abord le modèle sur mlx-serve, comme avant).
8. **Point d'entrée → Ouvrir LLMarium à la connexion** : le point d'entrée ne tourne que pendant que l'app est ouverte.

## Retour arrière

```bash
llmarium proxy port 18099
```

```bash
docker compose -f ~/Dev/server/llm-stack/docker-compose.yml start litellm
```

Puis couper et rallumer l'interrupteur du point d'entrée. Le `docker-compose.yml` et la configuration LiteLLM ne sont pas modifiés par l'app.
