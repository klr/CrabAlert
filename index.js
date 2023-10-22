const nodemailer = require('nodemailer');

const mailer = nodemailer.createTransport({
  port: 1025,
});

(async () => {
  await mailer.sendMail({
    to: 'karl@yellowred.blue',
    from: 'CrabAlert <no-reply@yellowred.blue>',
    subject: 'Crab Alert',
    body: 'Crab Alert!',
    html: 'Crab Alert!',
  }).then(res => {
    console.log(res);
  }).catch(err => {
    console.log(err);
  })
})();
