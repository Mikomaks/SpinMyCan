// Relay of phone notifications (Apple Notification Center Service, ANCS) to the app.
// Description for people: docs/NOTIFICATIONS.md.
//
// An iOS app cannot read the notifications of other apps, but the phone offers them to a
// paired Bluetooth accessory through ANCS — the same way a smartwatch gets them. The board
// is that accessory. It does not interpret anything: it subscribes to the two ANCS
// characteristics and passes the raw bytes on to the app over NOTIF_UUID; the app parses
// them (MySpin/PhoneNotifications.swift, covered by FeatureSelfTest) and writes ANCS
// commands back through the board.
//
// Rules:
//   - off until the app asks for it after EVERY connection (nothing is remembered here),
//     so with the switch in the app off the board behaves exactly as before v12,
//   - pairing is "Just Works" with bonding; the keys are created by the phone and the board
//     and stay in the board's flash (NVS) — there is no key in the source code,
//   - the notification bytes go back only over the connection they came from (the board
//     holds one connection: the phone),
//   - nothing is relayed during a firmware update — the whole link belongs to it.
//
// App → board (write):  [0x01] turn on   [0x00] turn off   [0x02][ANCS control point command]
// Board → app (notify): [0x10][state][reason]             state / reason: enums below
//                       [0x11][8 bytes]                   ANCS Notification Source packet
//                       [0x12][bytes]                     next piece of the ANCS Data Source stream

#pragma once
#include <Arduino.h>
#include <NimBLEDevice.h>
#include <freertos/FreeRTOS.h>
#include <freertos/message_buffer.h>

namespace notif {

enum State : uint8_t { OFF = 0, SECURING = 1, DISCOVERING = 2, READY = 3, FAILED = 4 };
enum Reason : uint8_t {
    NONE = 0,
    NO_SECURITY = 1,     // pairing refused or encryption failed
    NO_SERVICE = 2,      // the phone does not offer ANCS to us (notification sharing off?)
    NO_CHARS = 3,        // ANCS found, but not its three characteristics
    NO_SUBSCRIBE = 4,    // the phone refused the subscription
    TIMEOUT = 5,         // nobody accepted the pairing request in time
};
enum Msg : uint8_t { MSG_STATE = 0x10, MSG_SOURCE = 0x11, MSG_DATA = 0x12 };

static const uint32_t SETUP_TIMEOUT_MS = 45000;   // time for the rider to accept pairing on the phone
static const size_t   MAX_PACKET = 512;

static NimBLEUUID UUID_SERVICE("7905F431-B5CE-4E99-A40F-4B1E122D00D0");
static NimBLEUUID UUID_SOURCE("9FBF120D-6301-42D9-8C58-25E699A21DBD");
static NimBLEUUID UUID_CONTROL("69D1D8F3-45E1-49A8-9821-9BBDFDAAD9D9");
static NimBLEUUID UUID_DATA("22EAC6E9-24D6-4BB5-BE44-B36ACE7C7BFB");

static NimBLECharacteristic *chr = nullptr;
static MessageBufferHandle_t fromPhone = nullptr;   // ANCS packets: Bluetooth task → loop
static MessageBufferHandle_t fromApp = nullptr;     // commands of the app: Bluetooth task → loop
static volatile uint8_t state = OFF, reason = NONE;
static volatile bool stateDirty = false;
static volatile bool discoverPending = false;
static volatile uint32_t discoverAt = 0;
static uint8_t discoverTries = 0;
static uint32_t deadline = 0;
static uint16_t conn = 0;
static uint16_t svcStart = 0, svcEnd = 0;
static uint16_t hSource = 0, hControl = 0, hData = 0, cccdSource = 0, cccdData = 0;

static void setState(uint8_t s, uint8_t why = NONE) {
    state = s;
    reason = why;
    stateDirty = true;
}

static void forgetHandles() {
    svcStart = svcEnd = hSource = hControl = hData = cccdSource = cccdData = 0;
    discoverPending = false;
    discoverTries = 0;
}

static int onWritten(uint16_t, const struct ble_gatt_error *, struct ble_gatt_attr *, void *) { return 0; }

static int onSubscribedSource(uint16_t, const struct ble_gatt_error *err, struct ble_gatt_attr *, void *) {
    if (state != DISCOVERING) return 0;
    if (err->status == 0) setState(READY); else setState(FAILED, NO_SUBSCRIBE);
    return 0;
}

// Data Source first, then Notification Source — so the first notification can be asked about at once.
static int onSubscribedData(uint16_t c, const struct ble_gatt_error *err, struct ble_gatt_attr *, void *) {
    if (state != DISCOVERING) return 0;
    static const uint8_t on[2] = {0x01, 0x00};
    if (err->status != 0 || ble_gattc_write_flat(c, cccdSource, on, sizeof(on), onSubscribedSource, nullptr) != 0) {
        setState(FAILED, NO_SUBSCRIBE);
    }
    return 0;
}

static int onDescriptor(uint16_t c, const struct ble_gatt_error *err, uint16_t, const struct ble_gatt_dsc *d, void *) {
    if (state != DISCOVERING) return 0;
    if (err->status == 0 && d) {
        if (ble_uuid_u16(&d->uuid.u) == 0x2902) {
            // The subscription switch belongs to the nearest characteristic value before it.
            uint16_t owner = 0;
            const uint16_t values[3] = {hSource, hControl, hData};
            for (uint16_t v : values) if (v < d->handle && v > owner) owner = v;
            if (owner == hSource && !cccdSource) cccdSource = d->handle;
            if (owner == hData && !cccdData) cccdData = d->handle;
        }
        return 0;
    }
    static const uint8_t on[2] = {0x01, 0x00};
    if (err->status != BLE_HS_EDONE || !cccdSource || !cccdData
        || ble_gattc_write_flat(c, cccdData, on, sizeof(on), onSubscribedData, nullptr) != 0) {
        setState(FAILED, NO_CHARS);
    }
    return 0;
}

static int onCharacteristic(uint16_t c, const struct ble_gatt_error *err, const struct ble_gatt_chr *ch, void *) {
    if (state != DISCOVERING) return 0;
    if (err->status == 0 && ch) {
        if (ble_uuid_cmp(&ch->uuid.u, &UUID_SOURCE.getNative()->u) == 0) hSource = ch->val_handle;
        else if (ble_uuid_cmp(&ch->uuid.u, &UUID_CONTROL.getNative()->u) == 0) hControl = ch->val_handle;
        else if (ble_uuid_cmp(&ch->uuid.u, &UUID_DATA.getNative()->u) == 0) hData = ch->val_handle;
        return 0;
    }
    if (err->status != BLE_HS_EDONE || !hSource || !hControl || !hData
        || ble_gattc_disc_all_dscs(c, svcStart, svcEnd, onDescriptor, nullptr) != 0) {
        setState(FAILED, NO_CHARS);
    }
    return 0;
}

static int onService(uint16_t c, const struct ble_gatt_error *err, const struct ble_gatt_svc *svc, void *) {
    if (state != DISCOVERING) return 0;
    if (err->status == 0 && svc) {
        svcStart = svc->start_handle;
        svcEnd = svc->end_handle;
        return 0;
    }
    if (svcStart != 0 && err->status == BLE_HS_EDONE) {
        if (ble_gattc_disc_all_chrs(c, svcStart, svcEnd, onCharacteristic, nullptr) != 0) setState(FAILED, NO_CHARS);
        return 0;
    }
    // Right after pairing the phone may need a moment before it shows the service — try again.
    if (++discoverTries < 3) {
        discoverAt = millis() + 1500;
        discoverPending = true;
    } else {
        setState(FAILED, NO_SERVICE);
    }
    return 0;
}

// Called by the Bluetooth stack for every connection event (besides the library's own handler).
static int onGapEvent(struct ble_gap_event *ev, void *) {
    switch (ev->type) {
    case BLE_GAP_EVENT_ENC_CHANGE:
        if (state == SECURING && ev->enc_change.conn_handle == conn) {
            if (ev->enc_change.status == 0) {
                discoverAt = millis() + 400;
                discoverPending = true;
                setState(DISCOVERING);
            } else {
                setState(FAILED, NO_SECURITY);
            }
        }
        break;
    case BLE_GAP_EVENT_NOTIFY_RX:
        if (state == READY && ev->notify_rx.conn_handle == conn
            && (ev->notify_rx.attr_handle == hSource || ev->notify_rx.attr_handle == hData)) {
            static uint8_t buf[1 + MAX_PACKET];           // one Bluetooth task — a static buffer is safe
            uint16_t len = OS_MBUF_PKTLEN(ev->notify_rx.om);
            if (len > MAX_PACKET) len = MAX_PACKET;
            buf[0] = ev->notify_rx.attr_handle == hSource ? MSG_SOURCE : MSG_DATA;
            if (os_mbuf_copydata(ev->notify_rx.om, 0, len, buf + 1) == 0) {
                xMessageBufferSend(fromPhone, buf, size_t(len) + 1, 0);   // full queue = packet lost
            }
        }
        break;
    default:
        break;
    }
    return 0;
}

class AppEvents : public NimBLECharacteristicCallbacks {
    void onWrite(NimBLECharacteristic *c) override {
        NimBLEAttValue v = c->getValue();
        if (fromApp && v.length() > 0) xMessageBufferSend(fromApp, v.data(), v.length(), 0);
    }
};

// Creates the characteristic; call between createService() and its start().
static void begin(NimBLEService *svc, const char *uuid) {
    fromPhone = xMessageBufferCreate(4096);
    fromApp = xMessageBufferCreate(1024);
    chr = svc->createCharacteristic(uuid, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::NOTIFY);
    chr->setCallbacks(new AppEvents());
    // Pairing without a code, keys kept for the next connections. Nothing starts pairing
    // until the app turns the relay on.
    NimBLEDevice::setSecurityAuth(true, false, true);
    NimBLEDevice::setSecurityIOCap(BLE_HS_IO_NO_INPUT_OUTPUT);
    NimBLEDevice::setCustomGapHandler(onGapEvent);
}

// The phone disconnected: everything starts from zero on the next connection.
static void onDisconnect() {
    state = OFF;
    reason = NONE;
    stateDirty = false;
    forgetHandles();
    if (fromPhone) xMessageBufferReset(fromPhone);
    if (fromApp) xMessageBufferReset(fromApp);
}

static void turnOn(uint16_t connHandle, uint32_t now) {
    if (state == SECURING || state == DISCOVERING || state == READY) { stateDirty = true; return; }
    forgetHandles();
    conn = connHandle;
    deadline = now + SETUP_TIMEOUT_MS;
    struct ble_gap_conn_desc d;
    if (ble_gap_conn_find(conn, &d) != 0) { setState(FAILED, NO_SECURITY); return; }
    if (d.sec_state.encrypted) {
        discoverAt = now;
        discoverPending = true;
        setState(DISCOVERING);
        return;
    }
    setState(SECURING);
    int rc = ble_gap_security_initiate(conn);       // the phone shows the pairing request (first time only)
    if (rc != 0 && rc != BLE_HS_EALREADY) setState(FAILED, NO_SECURITY);
}

static void turnOff() {
    if (state == READY) {
        static const uint8_t off[2] = {0x00, 0x00};
        ble_gattc_write_flat(conn, cccdSource, off, sizeof(off), onWritten, nullptr);
        ble_gattc_write_flat(conn, cccdData, off, sizeof(off), onWritten, nullptr);
    }
    forgetHandles();
    setState(OFF);
}

static void send(const uint8_t *m, size_t n) {
    if (!chr) return;
    chr->setValue(m, n);
    chr->notify();
}

// From loop(). `busy` = a firmware update is running: commands are still obeyed, packets dropped.
static void poll(uint32_t now, bool connected, uint16_t connHandle, uint16_t mtu, bool busy) {
    if (!chr || !connected) return;
    static uint8_t buf[1 + MAX_PACKET];
    size_t n;
    while ((n = xMessageBufferReceive(fromApp, buf, sizeof(buf), 0)) > 0) {
        if (buf[0] == 0x01) turnOn(connHandle, now);
        else if (buf[0] == 0x00) turnOff();
        else if (buf[0] == 0x02 && n > 1 && state == READY) {
            ble_gattc_write_flat(conn, hControl, buf + 1, uint16_t(n - 1), onWritten, nullptr);
        }
    }
    if (state == DISCOVERING && discoverPending && int32_t(now - discoverAt) >= 0) {
        discoverPending = false;
        svcStart = svcEnd = 0;
        if (ble_gattc_disc_svc_by_uuid(conn, &UUID_SERVICE.getNative()->u, onService, nullptr) != 0) {
            setState(FAILED, NO_SERVICE);
        }
    }
    if ((state == SECURING || state == DISCOVERING) && int32_t(now - deadline) >= 0) {
        forgetHandles();
        setState(FAILED, TIMEOUT);
    }
    if (stateDirty) {
        stateDirty = false;
        const uint8_t m[3] = {MSG_STATE, state, reason};
        send(m, sizeof(m));
    }
    // One byte of every packet is our tag, so a full-size ANCS packet goes out in two pieces;
    // the Data Source is a byte stream anyway and the app glues it back together.
    size_t cap = mtu > 4 ? size_t(mtu) - 4 : 19;
    static uint8_t out[1 + MAX_PACKET];
    while ((n = xMessageBufferReceive(fromPhone, buf, sizeof(buf), 0)) > 1) {
        if (busy) continue;
        for (size_t off = 1; off < n; off += cap) {
            size_t take = n - off < cap ? n - off : cap;
            out[0] = buf[0];
            memcpy(out + 1, buf + off, take);
            send(out, take + 1);
        }
    }
}

}  // namespace notif
