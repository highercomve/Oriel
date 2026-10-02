import {TEXT_NODE} from '../shared/constants.js';
import {VALUE, NEXT, PREV} from '../shared/symbols.js';
import {String} from '../shared/utils.js';
import {escape} from '../shared/text-escaper.js';

import {CharacterData} from './character-data.js';

/**
 * @implements globalThis.Text
 */
export class Text extends CharacterData {
  constructor(ownerDocument, data = '') {
    super(ownerDocument, '#text', TEXT_NODE, data);
  }

  get wholeText() {
    const text = [];
    let {previousSibling, nextSibling} = this;
    while (previousSibling) {
      if (previousSibling.nodeType === TEXT_NODE)
        text.unshift(previousSibling[VALUE]);
      else
        break;
      previousSibling = previousSibling.previousSibling;
    }
    text.push(this[VALUE]);
    while (nextSibling) {
      if (nextSibling.nodeType === TEXT_NODE)
        text.push(nextSibling[VALUE]);
      else
        break;
      nextSibling = nextSibling.nextSibling;
    }
    return text.join('');
  }

  cloneNode() {
    const {ownerDocument, [VALUE]: data} = this;
    return new Text(ownerDocument, data);
  }

  toString() { return escape(this[VALUE]); }
}

// Oriel: document-created text needs the same fields and prototype as Text,
// without the Text/CharacterData/Node/EventTarget constructor chain.
export const createText = (ownerDocument, data = '') => {
  const node = Object.create(Text.prototype);
  node.ownerDocument = ownerDocument;
  node.localName = '#text';
  node.nodeType = TEXT_NODE;
  node.parentNode = null;
  node[NEXT] = null;
  node[PREV] = null;
  node[VALUE] = String(data);
  return node;
};
