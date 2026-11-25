import { test } from "node:test";
import assert from "node:assert/strict";
import { parseCsv } from "../scripts/import-csv.mjs";

test("puntkomma, Nederlandse kolommen, BOM en lege achternaam", () => {
  const rows = parseCsv("﻿E-mail;Voornaam;Achternaam\r\nanna@x.nl;Anna;de Boer\r\nbram@x.nl;Bram;-\r\n\r\n");
  assert.deepEqual(rows, [
    { email: "anna@x.nl", firstname: "Anna", lastname: "de Boer" },
    { email: "bram@x.nl", firstname: "Bram" },
  ]);
});

test("komma, Engelse kolommen, aanhalingstekens en id", () => {
  const rows = parseCsv('id,email,firstname,lastname\n12,"c@x.nl","Chris","Jansen, jr."\n');
  assert.deepEqual(rows, [{ id: "12", email: "c@x.nl", firstname: "Chris", lastname: "Jansen, jr." }]);
});

test("rijen zonder e-mail worden overgeslagen", () => {
  assert.equal(parseCsv("email;voornaam\n;Leeg\nd@x.nl;Dirk\n").length, 1);
});

test("duidelijke fout zonder e-mailkolom", () => {
  assert.throws(() => parseCsv("naam;telefoon\nA;1\n"), /Geen e-mailkolom/);
});
