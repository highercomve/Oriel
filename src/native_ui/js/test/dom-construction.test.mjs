import assert from 'node:assert/strict';
import { parseHTML } from '../vendor/linkedom/esm/index.js';
import { HTMLDivElement } from '../vendor/linkedom/esm/html/div-element.js';
import { HTMLElement } from '../vendor/linkedom/esm/html/element.js';
import { Text } from '../vendor/linkedom/esm/interface/text.js';
import { CLASS_LIST, END } from '../vendor/linkedom/esm/shared/symbols.js';

const { document, window } = parseHTML('<html><body></body></html>');
for (const [tag, Class] of [['div', HTMLElement], ['span', HTMLElement]]) {
  const actual = document.createElement(tag), reference = new Class(document, tag);
  assert.equal(Object.getPrototypeOf(actual), Object.getPrototypeOf(reference));
  assert.ok(actual instanceof Class);
  const describe = node => {
    const normalize = v => v === node ? 'self' : v === node[END] ? 'end' : v === document ? 'document' : v;
    return Reflect.ownKeys(node).map(key => [key, normalize(node[key])]);
  };
  assert.deepEqual(describe(actual), describe(reference), 'factory retains constructor instance fields and links');
  assert.deepEqual(Reflect.ownKeys(actual[END]), Reflect.ownKeys(reference[END]));
  for (const key of Reflect.ownKeys(reference[END])) {
    const value = reference[END][key];
    assert.equal(actual[END][key], value === reference ? actual : value);
  }
  for (const el of [actual, reference]) {
    el.className = 'plain';
    el.setAttribute('data-node', 'same');
    el.append(document.createTextNode('one'), document.createElement('span'));
    el.lastChild.textContent = 'two';
  }
  assert.equal(actual.outerHTML, reference.outerHTML);
  assert.equal(actual.cloneNode(true).outerHTML, reference.cloneNode(true).outerHTML);
  assert.equal(actual.querySelector('span').textContent, 'two');
  assert.equal(actual.firstChild.nextSibling, actual.lastChild);
  actual.firstChild.remove();
  assert.equal(actual.childNodes.length, 1);
}

for (const value of [undefined, null, '', 'one Ω', 3, { toString: () => 'converted' }]) {
  const text = document.createTextNode(value), reference = new Text(document, value);
  assert.equal(Object.getPrototypeOf(text), Text.prototype);
  assert.deepEqual(Reflect.ownKeys(text), Reflect.ownKeys(reference));
  for (const key of Reflect.ownKeys(reference)) assert.equal(text[key], reference[key]);
  assert.equal(text.cloneNode().data, reference.data);
  text.data = 'changed';
  assert.equal(text.nodeValue, 'changed');
}

const el = document.createElement('div');
assert.equal(el[CLASS_LIST], null);
el.className = 'row';
assert.equal(el.className, 'row');
assert.equal(el.getAttribute('class'), 'row');
assert.equal(el[CLASS_LIST], null, 'simple class writes and reads allocate no token Set');
el.setAttribute('class', 'next');
assert.equal(el.className, 'next');
const list = el.classList;
el.className = 'last';
assert.equal(el.classList, list, 'an exposed classList stays live across writes');
assert.ok(list.contains('last'));
list.add('extra');
assert.equal(el.className, 'last extra');
el.className = ' alpha  beta alpha\t';
assert.equal(el.className, 'alpha beta', 'general token normalization is preserved');
el.removeAttribute('class');
el.className = '';
assert.equal(el.getAttribute('class'), '');
assert.equal(el[CLASS_LIST], null);

const records = [];
const observer = new window.MutationObserver(r => records.push(...r));
const observed = document.createElement('span');
observer.observe(observed, { attributes: true, attributeOldValue: true });
observed.className = 'first';
observed.className = 'second';
await Promise.resolve();
assert.equal(records.length, 3, 'class writes preserve upstream observer notifications');
assert.deepEqual(records.map(r => r.oldValue), ['first', null, 'first']);
observer.disconnect();

let constructed = 0;
class CustomDiv extends HTMLDivElement {
  constructor(...args) { super(...args); constructed++; this.custom = true; }
}
window.customElements.define('construction-div', CustomDiv, { extends: 'div' });
const custom = document.createElement('div', { is: 'construction-div' });
assert.ok(custom instanceof CustomDiv);
assert.equal(custom.custom, true);
assert.equal(constructed, 1, 'customized built-ins retain their constructor path');
const late = document.createElement('div', { is: 'late-construction-div' });
class LateDiv extends HTMLDivElement {
  constructor(...args) { super(...args); this.upgraded = true; }
}
window.customElements.define('late-construction-div', LateDiv, { extends: 'div' });
window.customElements.upgrade(late);
assert.ok(late instanceof LateDiv);
assert.equal(late.upgraded, true);
assert.equal(late.getAttribute('is'), 'late-construction-div');
// Upstream also permits registrations without a dash. Preserve that route.
class CustomSpan extends HTMLElement {}
window.customElements.define('span', CustomSpan);
assert.ok(document.createElement('span') instanceof CustomSpan);
console.log('DOM construction: prototypes, instance fields, links, classes, observers and custom built-ins pass');
