const nodemailer = require('nodemailer');

const mailer = nodemailer.createTransport({
  port: 1025,
});

(async () => {
  await mailer.sendMail({
    to: 'karl@yellowred.blue',
    from: 'CrabAlert <no-reply@yellowred.blue>',
    subject: 'Confirm your e-mail',
    html: '\n<p>\n</p>\n <p>Test</p>\n <p>   To continue signing in to your account, please click <a href="#">this link</a>.</p><p>If you did not attempt to sign in you can ignore this e-mail.</p>',
  }).then(res => {
    console.log(res);
  }).catch(err => {
    console.log(err);
  })
})();
