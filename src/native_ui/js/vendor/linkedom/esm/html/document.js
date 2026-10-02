import {ELEMENT_NODE, NODE_END} from '../shared/constants.js';
import {CUSTOM_ELEMENTS, END, NEXT, PREV, START, PRIVATE, CLASS_LIST, DATASET, STYLE, UPGRADE} from '../shared/symbols.js';
import {htmlClasses} from '../shared/register-html-class.js';

import {Document} from '../interface/document.js';
import {NodeList} from '../interface/node-list.js';
import {customElements} from '../interface/custom-element-registry.js';

import {HTMLElement} from './element.js';

// Oriel: ordinary div/span nodes use HTMLElement without extra state. Initialize
// element in one frame instead of calling five constructors per node. Keep
// their exact prototypes and fields; custom elements/upgrades stay general.
const createPlainElement = (ownerDocument, localName) => {
  const element = Object.create(HTMLElement.prototype);
  element.ownerDocument = ownerDocument;
  element.localName = localName;
  element.nodeType = ELEMENT_NODE;
  element.parentNode = null;
  element[NEXT] = null;
  element[PREV] = null;
  element[PRIVATE] = null;
  element[NEXT] = element[END] = {
    [NEXT]: null, [PREV]: element, [START]: element,
    nodeType: NODE_END, ownerDocument, parentNode: null
  };
  element[CLASS_LIST] = null;
  element[DATASET] = null;
  element[STYLE] = null;
  return element;
};

const createHTMLElement = (ownerDocument, builtin, localName, options) => {
  if (!builtin && htmlClasses.has(localName)) {
    const Class = htmlClasses.get(localName);
    return new Class(ownerDocument, localName);
  }
  const {[CUSTOM_ELEMENTS]: {active, registry}} = ownerDocument;
  if (active) {
    const ce = builtin ? options.is : localName;
    if (registry.has(ce)) {
      const {Class} = registry.get(ce);
      const element = new Class(ownerDocument, localName);
      customElements.set(element, {connected: false});
      return element;
    }
  }
  if (!builtin && !ownerDocument[UPGRADE] && (localName === 'div' || localName === 'span'))
    return createPlainElement(ownerDocument, localName);
  return new HTMLElement(ownerDocument, localName);
};

/**
 * @implements globalThis.HTMLDocument
 */
export class HTMLDocument extends Document {
  constructor() { super('text/html'); }

  get all() {
    const nodeList = new NodeList;
    let {[NEXT]: next, [END]: end} = this;
    while (next !== end) {
      switch (next.nodeType) {
        case ELEMENT_NODE:
          nodeList.push(next);
          break;
      }
      next = next[NEXT];
    }
    return nodeList;
  }

  /**
   * @type HTMLHeadElement
   */
  get head() {
    const {documentElement} = this;
    let {firstElementChild} = documentElement;
    if (!firstElementChild || firstElementChild.tagName !== 'HEAD') {
      firstElementChild = this.createElement('head');
      documentElement.prepend(firstElementChild);
    }
    return firstElementChild;
  }

  /**
   * @type HTMLBodyElement
   */
  get body() {
    const {head} = this;
    let {nextElementSibling} = head;
    if (!nextElementSibling || nextElementSibling.tagName !== 'BODY') {
      nextElementSibling = this.createElement('body');
      head.after(nextElementSibling);
    }
    return nextElementSibling;
  }

  /**
   * @type HTMLTitleElement
   */
  get title() {
    const {head} = this;
    return head.getElementsByTagName('title').at(0)?.textContent || '';
  }

  set title(textContent) {
    const {head} = this;
    let title = head.getElementsByTagName('title').at(0);
    if (title)
      title.textContent = textContent;
    else {
      head.insertBefore(
        this.createElement('title'),
        head.firstChild
      ).textContent = textContent;
    }
  }

  createElement(localName, options) {
    const builtin = !!(options && options.is);
    const element = createHTMLElement(this, builtin, localName, options);
    if (builtin)
      element.setAttribute('is', options.is);
    return element;
  }
}
