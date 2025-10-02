#!/usr/bin/env bash
set -euo pipefail

# ----------------------------
# Configuración
# ----------------------------
STEP_DIR="./step"
CONTAINER="step-ca"
IMAGE="smallstep/step-ca:latest"
EAB_ENV=".stepca_eab.env"

# Cargar variables de .env
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

# Crear estructura de directorios
mkdir -p "$STEP_DIR/secrets" "$STEP_DIR/config" "$STEP_DIR/certs" "$STEP_DIR/db"
chmod -R 755 "$STEP_DIR"

# ----------------------------
# 1️⃣ Inicializar CA si no existe
# ----------------------------
if [[ ! -f "$STEP_DIR/config/ca.json" ]]; then
    echo "🔧 Inicializando CA..."

    # Detener el contenedor si está ejecutándose
    docker compose down "$CONTAINER" 2>/dev/null || true

    # Limpiar directorios si existe alguno corrupto
    if [ -d "$STEP_DIR/config" ] && [ ! -f "$STEP_DIR/config/ca.json" ]; then
        echo "⚠️ Directorio config existe pero sin ca.json, limpiando..."
        rm -rf "$STEP_DIR/config"/*
    fi

    # Crear archivo de contraseña persistente
    echo -n "$DOCKER_STEPCA_INIT_PASSWORD" > "$STEP_DIR/secrets/password"
    chmod 600 "$STEP_DIR/secrets/password"

    docker run --rm -i \
        -v "$(pwd)/$STEP_DIR:/home/step" \
        "$IMAGE" \
        step ca init \
            --name "$STEP_CA_NAME" \
            --dns "$STEP_CA_DNS" \
            --address "$STEP_CA_ADDRESS" \
            --provisioner "$STEP_CA_ADMIN_EMAIL" \
            --password-file=/home/step/secrets/password

    echo "✅ CA inicializada"
else
    echo "ℹ️  CA ya existe, no se reinicializa"
fi

# ----------------------------
# 2️⃣ Levantar step-ca
# ----------------------------
echo "🚀 Levantando step-ca..."

# Asegurarse de que todos los archivos tienen los permisos correctos
chmod -R 755 "$STEP_DIR"
find "$STEP_DIR/secrets" -type f -exec chmod 600 {} \;

docker compose up -d "$CONTAINER"

# ----------------------------
# 3️⃣ Esperar a que step-ca esté listo
# ----------------------------
echo "⏳ Esperando a que step-ca esté listo..."
TIMEOUT=30
for i in $(seq 1 $TIMEOUT); do
    if docker exec "$CONTAINER" sh -c 'pgrep step-ca >/dev/null'; then
        echo "✅ step-ca en ejecución"
        break
    fi
    echo -n "."
    sleep 1
    if [ "$i" -eq "$TIMEOUT" ]; then
        echo "❌ Timeout esperando a que step-ca esté listo. Revisar logs:"
        docker logs "$CONTAINER"
        exit 1
    fi
done

# ----------------------------
# 4️⃣ Crear provisioner ACME/EAB directamente en ca.json y generar credenciales
# ----------------------------
if ! grep -q '^STEP_EAB_KEYID=' .env 2>/dev/null; then
    echo "⚙️  Configurando provisioner ACME/EAB..."

    # 1️⃣ Comprobar si ya existe un provisioner ACME
    ACME_EXISTS=$(jq -r '.authority.provisioners[] | select(.type=="ACME") | .name' "$STEP_DIR/config/ca.json" || true)

    if [[ -z "$ACME_EXISTS" ]]; then
        echo "    ➕ Añadiendo provisioner ACME con EAB en ca.json..."

        # Generar un ID único para el provisioner EAB (32 bytes aleatorios en hex)
        EAB_KEY_ID=$(openssl rand -hex 16)

        # Crear una clave HMAC aleatoria (32 bytes codificados en base64 URL-safe)
        EAB_HMAC_KEY=$(openssl rand 32 | base64 -w0 | tr '+/' '-_' | tr -d '=')

        # Añadir ACME provisioner con configuración EAB
        jq --arg kid "$EAB_KEY_ID" --arg key "$EAB_HMAC_KEY" '.authority.provisioners += [{
            "type": "ACME",
            "name": "acme-provisioner",
            "claims": {
                "enableEAB": true
            },
            "options": {
                "x509": {
                    "defaultDuration": "2160h",
                    "minDuration": "720h",
                    "maxDuration": "8760h"
                }
            },
            "key": {
                "keyID": $kid,
                "hmacKey": $key
            }
        }]' "$STEP_DIR/config/ca.json" > "$STEP_DIR/config/ca.json.tmp" \
          && mv "$STEP_DIR/config/ca.json.tmp" "$STEP_DIR/config/ca.json"

        # Recargar la CA
        docker exec "$CONTAINER" kill -SIGHUP 1
        sleep 2

        # Asignar las claves generadas a las variables
        KEY_ID=$EAB_KEY_ID
        HMAC_KEY=$EAB_HMAC_KEY

        echo "    ✅ Provisioner ACME creado con EAB: $EAB_KEY_ID"
    else
        echo "    ✅ Provisioner ACME ya existe: $ACME_EXISTS"

        # Extraer las credenciales EAB existentes
        KEY_ID=$(jq -r '.authority.provisioners[] | select(.type=="ACME") | .key.keyID // empty' "$STEP_DIR/config/ca.json")
        HMAC_KEY=$(jq -r '.authority.provisioners[] | select(.type=="ACME") | .key.hmacKey // empty' "$STEP_DIR/config/ca.json")

        # Si no tiene credenciales EAB, añadirlas
        if [[ -z "$KEY_ID" || -z "$HMAC_KEY" ]]; then
            echo "    ➕ Actualizando provisioner ACME con EAB..."

            # Generar nuevas credenciales
            EAB_KEY_ID=$(uuidgen | tr -d '-')
            EAB_HMAC_KEY=$(openssl rand -base64 32)

            # Actualizar el provisioner con las nuevas credenciales
            PROVISIONER_INDEX=$(jq -r '.authority.provisioners | map(.type == "ACME") | index(true)' "$STEP_DIR/config/ca.json")

            jq --arg idx "$PROVISIONER_INDEX" --arg kid "$EAB_KEY_ID" --arg key "$EAB_HMAC_KEY" '
            .authority.provisioners[$idx | tonumber].claims.enableEAB = true |
            .authority.provisioners[$idx | tonumber].key = {
                "keyID": $kid,
                "hmacKey": $key
            }' "$STEP_DIR/config/ca.json" > "$STEP_DIR/config/ca.json.tmp" \
              && mv "$STEP_DIR/config/ca.json.tmp" "$STEP_DIR/config/ca.json"

            # Recargar la CA
            docker exec "$CONTAINER" kill -SIGHUP 1
            sleep 2

            # Asignar las claves generadas a las variables
            KEY_ID=$EAB_KEY_ID
            HMAC_KEY=$EAB_HMAC_KEY

            echo "    ✅ Provisioner ACME actualizado con EAB"
        fi
    fi

    # Verificar que tenemos las credenciales
    if [[ -z "$KEY_ID" || -z "$HMAC_KEY" ]]; then
        echo "❌ No se pudieron generar las credenciales EAB. Error inesperado."
        exit 1
    fi

    # 4️⃣ Guardar en .env para que Traefik pueda leerlas (asegurando formato correcto)
    echo "STEP_EAB_KEYID=$KEY_ID" >> .env
    # Asegurar que la clave HMAC está en base64 URL-safe sin padding
    HMAC_ENCODED=$(echo -n "$HMAC_KEY" | tr '+/' '-_' | tr -d '=')
    echo "STEP_EAB_HMAC=$HMAC_ENCODED" >> .env
    # También muestra las credenciales para depuración
    echo "✅ Credenciales EAB generadas y guardadas en .env:"
    echo "   STEP_EAB_KEYID=$KEY_ID"
    echo "   STEP_EAB_HMAC=$HMAC_KEY"
else
    echo "ℹ️  Credenciales EAB ya existen en .env, no se regeneran"
fi



echo "🎉 Todo listo. Traefik ahora puede generar certificados HTTPS para tus servicios locales."
